# Zammad with the package baked in, as a deployment would build it: the files copied over the upstream
# image and the frontend assets recompiled so the CoffeeScript and templates reach the browser.
ARG ZAMMAD_IMAGE=ghcr.io/zammad/zammad:7.2.2-0000
FROM ${ZAMMAD_IMAGE}

USER root

# assets:precompile needs Node for ExecJS and pnpm for the Vite build.
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl gnupg \
  && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
  && apt-get install -y --no-install-recommends nodejs \
  && npm install -g pnpm \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

COPY --chown=zammad:zammad app/ /opt/zammad/app/
COPY --chown=zammad:zammad config/ /opt/zammad/config/
COPY --chown=zammad:zammad db/ /opt/zammad/db/
COPY --chown=zammad:zammad lib/ /opt/zammad/lib/

USER zammad
