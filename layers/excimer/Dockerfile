ARG PHP_VERSION
ARG BREF_VERSION
# For ARM64 use your own image built from Bref aws-lambda-layers (e.g. myuser/bref-build-php-84:2)
ARG BREF_BUILD_IMAGE
FROM ${BREF_BUILD_IMAGE} AS ext

RUN pecl install excimer
RUN cp `php-config --extension-dir`/excimer.so /tmp/excimer.so
RUN echo 'extension=excimer.so' > /tmp/ext.ini

# Build the final image with just the files we need
FROM scratch

# Copy things we installed to the final image
COPY --from=ext /tmp/excimer.so /opt/bref/extensions/excimer.so
COPY --from=ext /tmp/ext.ini /opt/bref/etc/php/conf.d/ext-excimer.ini
