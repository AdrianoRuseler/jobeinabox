# Jobe-in-a-box: a Dockerised Jobe server
FROM ubuntu:26.04
LABEL \
    org.opencontainers.image.authors="richard.lobb@canterbury.ac.nz,j.hoedjes@hva.nl,d.h.bowes@herts.ac.uk" \
    org.opencontainers.image.title="JobeInABox" \
    org.opencontainers.image.description="JobeInABox" \
    org.opencontainers.image.documentation="https://github.com/trampgeek/jobeinabox" \
    org.opencontainers.image.source="https://github.com/trampgeek/jobeinabox"

ARG TZ=America/Sao_Paulo
ARG JOBE_VERSION=master

# Set up Apache environment variables
ENV APACHE_RUN_USER=www-data \
    APACHE_RUN_GROUP=www-data \
    APACHE_LOG_DIR=/var/log/apache2 \
    APACHE_LOCK_DIR=/var/lock/apache2 \
    APACHE_PID_FILE=/var/run/apache2.pid \
    LANG=C.UTF-8 \
    # CHANGED: Required on Ubuntu to suppress interactive apt prompts
    DEBIAN_FRONTEND=noninteractive

# Copy configuration files after the heavy apt layer so config edits
# don't invalidate the package cache.  (moved from top)
# Layer 1: Install system packages (Changes infrequently -> Heavily cached)
RUN ln -snf /usr/share/zoneinfo/"$TZ" /etc/localtime && \
    echo "$TZ" > /etc/timezone && \
    apt-get update && \
    apt-get --no-install-recommends install -yq \
        acl \
        apache2 \
        build-essential \
        fp-compiler \
        git \
        libapache2-mod-php \
        # CHANGED: ubuntu:26.04 ships nodejs 20+; explicit version pin
        # removed so apt picks the distro default (no PPA needed)
        nodejs \
        octave \
        # CHANGED: pulls OpenJDK 25 on Ubuntu 26.04 (was 21 on 24.04)
        default-jdk \
        php \
        php-cli \
        php-mbstring \
        php-intl \
        python3 \
        python3-pip \
        python3-setuptools \
        pylint \
        sqlite3 \
        sudo \
        tzdata \
        unzip && \
    pylint --reports=no --score=n --generate-rcfile > /etc/pylintrc && \
    apt-get -y autoremove --purge && \
    apt-get -y clean && \
    rm -rf /var/lib/apt/lists/*

# CHANGED: COPY moved here so edits to config files don't bust the apt cache above
COPY 000-jobe.conf /
COPY container-test.sh /
COPY index.html /

# Layer 2: Configure Apache & Fetch Jobe (Uses secrets securely)
RUN --mount=type=secret,id=api_keys \
    # Redirect Apache logs to stdout/stderr
    ln -sf /proc/self/fd/1 /var/log/apache2/access.log && \
    ln -sf /proc/self/fd/1 /var/log/apache2/error.log && \
    # Apache Setup
    sed -i "s/export LANG=C/export LANG=$LANG/" /etc/apache2/envvars && \
    sed -i '1 i ServerName localhost' /etc/apache2/apache2.conf && \
    sed -i 's/ServerTokens\ OS/ServerTokens \Prod/g' /etc/apache2/conf-enabled/security.conf && \
    sed -i 's/ServerSignature\ On/ServerSignature \Off/g' /etc/apache2/conf-enabled/security.conf && \
    rm -f /etc/apache2/sites-enabled/000-default.conf && \
    mv /000-jobe.conf /etc/apache2/sites-enabled/ && \
    # Web Directory Setup
    mkdir -p /var/crash && \
    chmod 755 /var/crash && \
    chown ${APACHE_RUN_USER}:${APACHE_RUN_GROUP} /var/crash && \
    mv /index.html /var/www/html/index.html && \
    # Clone Jobe
    git clone --depth=1 --single-branch --branch ${JOBE_VERSION} \
        https://github.com/trampgeek/jobe.git /var/www/html/jobe && \
    rm -rf /var/www/html/jobe/.git && \
    cd /var/www/html/jobe && \
    # FIX 1: read secret safely; 2>/dev/null prevents fatal error when
    # no secret file is provided at build time
    API_KEYS=$(cat /run/secrets/api_keys 2>/dev/null | tr '\n' ' ') && \
    if [ -n "${API_KEYS}" ]; then \
        sed -i 's/\$require_api_keys = false/\$require_api_keys = true/' \
            /var/www/html/jobe/app/Config/Jobe.php && \
        perl -i -pe "s|'2AAA7A.*|${API_KEYS}|" \
            /var/www/html/jobe/app/Config/Jobe.php \
    ; fi && \
    # FIX 2: jobe/install probes for the www-data process to find the
    # web server uid, so Apache must be running during install.
    # Start it, install, then stop cleanly to avoid stale PID in image.
    apache2ctl start && \
    /usr/bin/python3 /var/www/html/jobe/install --max_uid=500 && \
    apache2ctl stop && \
    rm -f ${APACHE_PID_FILE} && \
    chown -R ${APACHE_RUN_USER}:${APACHE_RUN_GROUP} /var/www/html

# Layer 3: Fix language version detection regressions on Ubuntu 26.04
RUN \
    # Java: OpenJDK 25 no longer defaults stdout to UTF-8
    sed -i \
        "s|public string \$java_extraflags = '';|public string \$java_extraflags = '-Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8';|" \
        /var/www/html/jobe/app/Config/Jobe.php && \
    # Octave: Ubuntu 26.04 changed version string to include arch tuple:
    #   old: "GNU Octave, version 8.x"
    #   new: "GNU Octave (x86_64-pc-linux-gnu) version 11.x"
    sed -i \
        's|GNU Octave, version (\[0-9._\]\*)|GNU Octave[^0-9]*([0-9][0-9._]*)|' \
        /var/www/html/jobe/app/Libraries/OctaveTask.php

EXPOSE 80

HEALTHCHECK --interval=1m --timeout=2s \
    CMD /usr/bin/python3 /var/www/html/jobe/minimaltest.py || exit 1

CMD ["/usr/sbin/apache2ctl", "-D", "FOREGROUND"]
