# base - only install packages shared across all images, or stuff needed
# for production. It's easiest to build off of an official openjdk image
# vs ruby, python, or building from scratch. If this needs to built from
# a clean base image, reproduce how openjdk builds their images.
FROM openjdk:14-jdk-slim-buster as base

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get -y install --no-install-recommends \
    ruby2.5 \
    wget \
    curl \
    && rm -rf /var/lib/apt/lists/*

# dev - python+sphinx for docs, build tools, etc
FROM base AS dev
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get -y install --no-install-recommends \
    build-essential \
    git \
    vim \
    ruby2.5-dev \
    zlib1g-dev \
    python3 \
    python3-sphinx \
    && rm -rf /var/lib/apt/lists/*

RUN gem install bundler --no-document

# builder
FROM dev AS builder
COPY . /src
WORKDIR /src
RUN bundle install --quiet
RUN bundle exec rake build && \
    bundle exec rake tests:prepare && \
    bundle exec rspec

# gem
FROM base as gem
RUN mkdir -p /gem
COPY --from=builder /src/pkg/* /gem/
