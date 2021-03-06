FROM ubuntu:18.04

# Based on
# https://switch2osm.org/manually-building-a-tile-server-18-04-lts/

# Set up environment
ENV TZ=UTC
ENV AUTOVACUUM=on
ENV UPDATES=disabled
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Install dependencies
RUN apt-get update \
  && apt-get install -y locales wget gnupg2 lsb-core apt-transport-https ca-certificates curl \
  && wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add - \
  && echo "deb [ trusted=yes ] https://apt.postgresql.org/pub/repos/apt/ `lsb_release -cs`-pgdg main" | tee /etc/apt/sources.list.d/pgdg.list \
  && wget --quiet -O - https://deb.nodesource.com/setup_10.x | bash - \
  && apt-get update \
  && apt-get install -y nodejs \
  && apt-get update \
  && apt-get install -y software-properties-common

RUN apt-get install -y --no-install-recommends \
  apache2 \
  apache2-dev \
  autoconf \
  build-essential \
  bzip2 \
  cmake \
  cron \
  fonts-noto-cjk \
  fonts-noto-hinted \
  fonts-noto-unhinted \
  gcc \
  git-core \
  libagg-dev \
  libboost-filesystem-dev \
  libboost-system-dev \
  libbz2-dev \
  libcairo-dev \
  libcairomm-1.0-dev \
  libexpat1-dev \
  libfreetype6-dev \
  libgeos++-dev \
  libgeos-dev \
  libgeotiff-epsg \
  libicu-dev \
  liblua5.3-dev \
  libmapnik-dev \
  libpq-dev \
  libproj-dev \
  libprotobuf-c0-dev \
  libtiff5-dev \
  libtool \
  libxml2-dev \
  lua5.3 \
  make \
  mapnik-utils \
  node-gyp \
  osmium-tool \
  osmosis \
  postgis \
  postgresql-12 \
  postgresql-contrib-12 \
  postgresql-server-dev-12 \
  protobuf-c-compiler \
  python3-mapnik \
  python3-lxml \
  python3-psycopg2 \
  python3-shapely \
  python3-pip \
  sudo \
  tar \
  ttf-unifont \
  unzip \
  wget \
  zlib1g-dev

# Install Python utilities for loading shapefiles.
RUN pip3 install pyyaml requests

# Install newer version of GDAL.
RUN add-apt-repository ppa:ubuntugis/ubuntugis-unstable && apt-get update && apt-get install -y --no-install-recommends \
  gdal-bin \
  libgdal-dev \
 && apt-get clean autoclean \
 && apt-get autoremove --yes \
 && rm -rf /var/lib/{apt,dpkg,cache,log}

# Set up PostGIS
RUN wget https://download.osgeo.org/postgis/source/postgis-3.0.0.tar.gz -O postgis.tar.gz \
 && mkdir -p postgis_src \
 && tar -xvzf postgis.tar.gz --strip 1 -C postgis_src \
 && rm postgis.tar.gz \
 && cd postgis_src \
 && ./configure \
 && make -j $(nproc) \
 && make -j $(nproc) install \
 && cd .. && rm -rf postgis_src

# Set up renderer user
RUN adduser --disabled-password --gecos "" renderer

# Install latest osm2pgsql
RUN mkdir -p /home/renderer/src \
 && cd /home/renderer/src \
 && git clone -b master https://github.com/openstreetmap/osm2pgsql.git --depth 1 \
 && cd /home/renderer/src/osm2pgsql \
 && rm -rf .git \
 && mkdir build \
 && cd build \
 && cmake .. \
 && make -j $(nproc) \
 && make -j $(nproc) install \
 && mkdir /nodes \
 && chown renderer:renderer /nodes \
 && rm -rf /home/renderer/src/osm2pgsql

# Install mod_tile and renderd
RUN mkdir -p /home/renderer/src \
 && cd /home/renderer/src \
 && git clone -b switch2osm https://github.com/SomeoneElseOSM/mod_tile.git --depth 1 \
 && cd mod_tile \
 && rm -rf .git \
 && ./autogen.sh \
 && ./configure \
 && make -j $(nproc) \
 && make -j $(nproc) install \
 && make -j $(nproc) install-mod_tile \
 && ldconfig \
 && cd ..

# Configure renderd
COPY renderd.conf /usr/local/etc/

# Configure Apache
RUN mkdir /var/lib/mod_tile \
 && chown renderer /var/lib/mod_tile \
 && mkdir /var/run/renderd \
 && chown renderer /var/run/renderd \
 && echo "LoadModule tile_module /usr/lib/apache2/modules/mod_tile.so" >> /etc/apache2/conf-available/mod_tile.conf \
 && echo "LoadModule headers_module /usr/lib/apache2/modules/mod_headers.so" >> /etc/apache2/conf-available/mod_headers.conf \
 && a2enconf mod_tile && a2enconf mod_headers

# Configure Leaflet
COPY apache.conf /etc/apache2/sites-available/000-default.conf
COPY leaflet-demo.html /var/www/html/index.html
COPY leaflet-side-by-side.js /var/www/html/
COPY layout.css /var/www/html/
COPY range.css /var/www/html/
COPY L.Control.ZoomDisplay.css /var/www/html/
COPY L.Control.ZoomDisplay.js /var/www/html/

RUN ln -sf /dev/stdout /var/log/apache2/access.log \
 && ln -sf /dev/stderr /var/log/apache2/error.log

# Configure PosgtreSQL
COPY postgresql.custom.conf.tmpl /etc/postgresql/12/main/
RUN chown -R postgres:postgres /var/lib/postgresql \
 && chown postgres:postgres /etc/postgresql/12/main/postgresql.custom.conf.tmpl \
 && echo "host all all all md5" >> /etc/postgresql/12/main/pg_hba.conf \
 && echo "host all all ::/0 md5" >> /etc/postgresql/12/main/pg_hba.conf

# Copy update scripts
COPY openstreetmap-tiles-update-expire /usr/bin/
RUN chmod +x /usr/bin/openstreetmap-tiles-update-expire \
 && mkdir /var/log/tiles \
 && chmod a+rw /var/log/tiles \
 && ln -s /home/renderer/src/mod_tile/osmosis-db_replag /usr/bin/osmosis-db_replag \
 && echo "*  *    * * *   renderer    openstreetmap-tiles-update-expire\n" >> /etc/crontab

# Install trim_osc.py helper script
RUN mkdir -p /home/renderer/src \
 && cd /home/renderer/src \
 && git clone https://github.com/zverik/regional \
 && cd regional \
 && git checkout 612fe3e040d8bb70d2ab3b133f3b2cfc6c940520 \
 && rm -rf .git \
 && chmod u+x /home/renderer/src/regional/trim_osc.py

# Configure stylesheets
RUN mkdir -p /home/renderer/src/openstreetmap-carto/data

COPY openstreetmap-carto/ /home/renderer/src/openstreetmap-carto/
COPY get-shapefiles.py /home/renderer/src/openstreetmap-carto/scripts

RUN cd /home/renderer/src/openstreetmap-carto \
 && rm -rf .git \
 && npm install -g carto@0.18.2 \
 && carto project.mml > mapnik.xml \
 && scripts/get-shapefiles.py \
 && rm /home/renderer/src/openstreetmap-carto/data/*.zip

RUN mkdir -p /home/renderer/src/osm-carto-highcontrast

COPY osm-carto-highcontrast/ /home/renderer/src/osm-carto-highcontrast/

RUN cd /home/renderer/src/osm-carto-highcontrast \
 && rm -rf .git \
 && carto project.mml > mapnik.xml \
 && ln -s /home/renderer/src/openstreetmap-carto/data .

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

# Start running
COPY run.sh /
COPY indexes.sql /
ENTRYPOINT ["/run.sh"]
CMD []

EXPOSE 80 5432
