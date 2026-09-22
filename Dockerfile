FROM ruby:3.3.7-slim-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake pkg-config libssl-dev libssh2-1-dev \
    libcurl4-openssl-dev build-essential libpq-dev \
    git curl ca-certificates xz-utils && \
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash - && \
    apt-get install -y nodejs && \
    npm install -g corepack && \
    corepack enable && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock* ./
RUN bundle config set --local build.rugged --with-ssh && \
    bundle config set --local without 'development test' && \
    bundle install --jobs=4

COPY . .

RUN cp config/database.pg.yml config/database.yml && \
    cp config/cable.yml.sample config/cable.yml && \
    cp certs/v2_key.dev certs/v2_key

COPY docker/database.yml config/database.yml

RUN GEM_UI=$(bundle show manageiq-ui-classic) && \
    node -e " \
      const fs = require('fs'); \
      const p = process.env.GEM_UI + '/package.json'; \
      const pkg = JSON.parse(fs.readFileSync(p)); \
      pkg.resolutions = { \
        ...pkg.resolutions, \
        '@babel/core': '^7.0.0', \
        '@babel/preset-env': '^7.0.0', \
        '@babel/preset-react': '^7.0.0', \
        '@babel/preset-typescript': '^7.0.0', \
        '@babel/traverse': '^7.0.0', \
        '@babel/types': '^7.0.0', \
        '@babel/template': '^7.0.0', \
        '@babel/helpers': '^7.0.0', \
        '@babel/generator': '^7.0.0', \
        '@babel/parser': '^7.0.0', \
        '@babel/code-frame': '^7.0.0', \
        'babel-plugin-polyfill-corejs2': '^0.0.0', \
        'babel-plugin-polyfill-corejs3': '^0.0.0', \
        'babel-plugin-polyfill-regenerator': '^0.0.0' \
      }; \
      fs.writeFileSync(p, JSON.stringify(pkg, null, 2)); \
      console.log('Patched babel resolutions'); \
    "

RUN RAILS_ENV=production SECRET_KEY_BASE=placeholder bundle exec rake update:ui
RUN RAILS_ENV=production SECRET_KEY_BASE=placeholder bundle exec rake assets:precompile

FROM ruby:3.3.7-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    libpq-dev libssl-dev libssh2-1 libcurl4 libgit2-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY --from=builder /app /app

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV RAILS_ENV=production
ENV RAILS_SERVE_STATIC_FILES=true
ENV RAILS_LOG_TO_STDOUT=true

EXPOSE 3000

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0", "-p", "3000"]
