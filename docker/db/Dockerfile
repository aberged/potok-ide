# The dev and test database: the official Postgres 16 image (Debian trixie)
# with PostGIS from the PGDG repository it already carries. postgis/postgis
# images run an older Debian, whose collation would not match a database
# made by postgres:16.
FROM postgres:16

RUN apt-get update \
  && apt-get install -y --no-install-recommends postgresql-16-postgis-3 \
  && rm -rf /var/lib/apt/lists/*
