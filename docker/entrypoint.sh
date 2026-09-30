#!/bin/bash
set -e

echo "==> Rendering database.yml from environment..."
envsubst '${DB_HOST} ${DB_USER} ${DB_PASSWORD} ${DB_NAME}' < config/database.yml > /tmp/database.yml.rendered
mv /tmp/database.yml.rendered config/database.yml

if [ "$RUN_MIGRATIONS" = "true" ]; then
  echo "==> Running migrations..."
  bundle exec rails db:create db:migrate

  echo "==> Ensuring core records (region, zone, server) exist..."
  bundle exec rails runner "EvmDatabase.seed_primordial"

  echo "==> Seeding if fresh install..."
  bundle exec rails runner "
    if User.where(userid: 'admin').none?
      puts 'Seeding initial data...'
      load Rails.root.join('db/seeds.rb')
    else
      puts 'Seed data already present, skipping.'
    end
  "
else
  echo "==> Skipping migrations (RUN_MIGRATIONS is not true)."
fi

echo "==> Starting: $@"
exec "$@"