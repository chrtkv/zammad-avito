# Test runner for the package inside Zammad's source tree. Same base image as Zammad's own devcontainer.
FROM ghcr.io/rails/devcontainer/images/ruby:3.4.9

USER root
RUN apt-get update \
  && apt-get install -y --no-install-recommends libimlib2-dev libpq-dev postgresql-client rsync \
  && rm -rf /var/lib/apt/lists/*

# The base image installs Ruby for its vscode user through mise; the runner works as root.
ENV PATH=/home/vscode/.local/share/mise/installs/ruby/3.4.9/bin:$PATH \
    BUNDLE_PATH=/bundle \
    BUNDLE_WITHOUT="" \
    RAILS_ENV=test
