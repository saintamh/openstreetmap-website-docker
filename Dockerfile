## -*- docker-image-name: "homme/openstreetmap-website:latest" -*-

##
# The OpenStreetMap Website
#
# This creates an image with the OpenStreetMap 'Rails Port'. This is the OSM
# database and server side components.  Further details can be found at
# <https://github.com/openstreetmap/openstreetmap-website/blob/master/INSTALL.md>.
#

FROM phusion/baseimage:0.9.19
MAINTAINER Homme Zwaagstra <hrz@geodata.soton.ac.uk>

# Set the locale. This affects the encoding of the Postgresql template
# databases.
ENV LANG C.UTF-8
RUN update-locale LANG=C.UTF-8

# Install Osmosis. Shouldn't need to be altered so put it here to make
# rebuilding quicker.
RUN apt-get update -y
ADD install-osmosis.sh /tmp/
RUN sh /tmp/install-osmosis.sh
ADD install-fuse.sh /tmp/
RUN sh /tmp/install-fuse.sh
ADD install-java.sh /tmp/
RUN sh /tmp/install-java.sh

# We want the production OSM setup
ENV RAILS_ENV production

# Install the openstreetmap-website dependencies
RUN apt-get install -y ruby2.3 libruby2.3 ruby2.3-dev \
                     libmagickwand-dev libxml2-dev libxslt1-dev nodejs \
                     apache2 apache2-dev build-essential \
                     postgresql postgresql-contrib libpq-dev postgresql-server-dev-all \
                     libsasl2-dev sudo
RUN gem2.3 install bundle

# Get the `openstreetmap-website` code
RUN cd /tmp && \
    curl --location https://github.com/openstreetmap/openstreetmap-website/archive/master.tar.gz | tar xz
RUN rm -rf /var/www && mv /tmp/openstreetmap-website-master /var/www

# Install the javascript runtime required by the `execjs` gem in
# openstreetmap-website
RUN apt-get install -y libv8-dev
RUN cd /var/www && \
    echo "gem 'therubyracer'" >> Gemfile

# Install the required ruby gems
RUN cd /var/www && bundle install

# Configure the application
RUN cd /var/www && cp config/example.application.yml config/application.yml

# Configure the database
RUN cd /var/www && cp config/example.database.yml config/database.yml

# Precompile the website assets
RUN cd /var/www && bundle exec rake assets:precompile

# The rack interface requires a `tmp` directory
RUN ln -s /tmp /var/www/tmp

# Add the production and development sites for Apache
ADD apache-production.conf /etc/apache2/sites-available/production.conf
ADD apache-development.conf /etc/apache2/sites-available/development.conf
RUN a2dissite 000-default

# Ensure apache has appropriate permissions
RUN chown -R www-data: /var/www

# Create the OSM postgresql database extension
RUN cd /var/www/db/functions && make libpgosm.so

# Ensure the webserver user can connect to the osm databases.  This uses
# `trust` and not `peer` authentication because the `import` option on the
# container runs `osmosis` which uses TCP/IP connections: `peer` authentication
# is only valid for unix socket connections.
RUN sed -i -e 's/host    all             all             127.0.0.1\/32            md5/host osm,openstreetmap www-data 127.0.0.1\/32 trust/' /etc/postgresql/9.5/main/pg_hba.conf

# Install Phusion Passenger from instructions at
# https://www.phusionpassenger.com/library/walkthroughs/deploy/ruby/ownserver/apache/oss/xenial/install_passenger.html
RUN apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 561F9B9CAC40B2F7
RUN apt-get install -y apt-transport-https ca-certificates
RUN sh -c 'echo deb https://oss-binaries.phusionpassenger.com/apt/passenger xenial main > /etc/apt/sources.list.d/passenger.list'
RUN apt-get update -y
RUN apt-get install -y libapache2-mod-passenger

# Install openstreetmap-cgimap from instructions at
# <https://github.com/zerebubuth/openstreetmap-cgimap>.
RUN apt-get install -y libxml2-dev libpqxx-dev libfcgi-dev \
  libboost-dev libboost-regex-dev libboost-program-options-dev \
  libboost-date-time-dev libboost-filesystem-dev \
  libboost-system-dev libboost-locale-dev libmemcached-dev \
  libcrypto++-dev \
  automake autoconf
RUN cd /tmp && \
    curl --location https://github.com/zerebubuth/openstreetmap-cgimap/archive/master.tar.gz | tar xz
RUN cd /tmp/openstreetmap-cgimap-master/ && \
    ./autogen.sh && \
    ./configure --with-fcgi=/usr && \
    make && make install

# daemontools provides the `fghack` program required for running the `cgimap`
# service
RUN apt-get install -y daemontools

# Enable required apache modules for the cgimap Apache service
RUN a2enmod proxy proxy_http rewrite
    
# Install mod_fastcgi_handler
RUN cd /tmp && \
    curl --location https://github.com/hollow/mod_fastcgi_handler/archive/master.tar.gz | tar xz
RUN cd /tmp/mod_fastcgi_handler-master && \
    apxs2 -i -a -o mod_fastcgi_handler.so -c *.c

# Enable cgimap in Apache. The conf file is taken from
# <https://github.com/zerebubuth/openstreetmap-cgimap/blob/master/scripts/cgimap.conf>.
ADD cgimap.conf /tmp/
RUN sed -e 's/RewriteRule ^(.*)/#RewriteRule ^(.*)/' \
        -e 's/\/var\/www/\/var\/www\/public/g' \
        /tmp/cgimap.conf > /etc/apache2/sites-available/cgimap.conf
RUN chmod 644 /etc/apache2/sites-available/cgimap.conf

# Tune postgresql
ADD postgresql.conf.sed /tmp/
RUN sed --file /tmp/postgresql.conf.sed --in-place /etc/postgresql/9.5/main/postgresql.conf

# Define the application logging logic
ADD syslog-ng.conf /etc/syslog-ng/conf.d/local.conf
RUN rm -rf /var/log/postgresql

# Create a `postgresql` `runit` service
ADD postgresql /etc/sv/postgresql
RUN update-service --add /etc/sv/postgresql

# Create a `cgimap` `runit` service
ADD cgimap /etc/sv/cgimap
RUN update-service --add /etc/sv/cgimap

# Create a `devserver` `runit` service for running the development rails server
ADD devserver /etc/sv/devserver
RUN update-service --add /etc/sv/devserver

# Create an `apache2` `runit` service
ADD apache2 /etc/sv/apache2
RUN update-service --add /etc/sv/apache2

# Clean up APT when done
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Expose the webserver and database ports
EXPOSE 80 5432

# We need the volume for importing data from
VOLUME ["/data"]

# Add the README
ADD README.md /usr/local/share/doc/

# Add the help file
RUN mkdir -p /usr/local/share/doc/run
ADD help.txt /usr/local/share/doc/run/help.txt

ENV SECRET_KEY_BASE 7fe3b48a79b2f36eb78a4685224d707767d083f79c51f7d81a9d4a06d1c1e253410d52b1bf88c429e73ffbc5e5f58b037db21f38ea88b8b454e55d52ed8bcc6e

# Add the entrypoint
ADD run.sh /usr/local/sbin/run
ENTRYPOINT ["/sbin/my_init", "--", "/usr/local/sbin/run"]

# Default to showing the usage text
CMD ["help"]
