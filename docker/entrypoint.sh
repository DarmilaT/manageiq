#!/bin/bash
set -e

echo "==> Waiting for database..."
until bundle exec rails runner "ActiveRecord::Base.connection.execute('SELECT 1')" 2>/dev/null; do
  echo "    Database not ready, retrying in 3s..."
  sleep 3
done
echo "==> Database ready."

echo "==> Running migrations..."
bundle exec rails db:create db:migrate

echo "==> Seeding if fresh install..."
bundle exec rails runner "
  if User.where(userid: 'admin').none?
    puts 'Seeding initial data...'
    load Rails.root.join('db/seeds.rb')
  else
    puts 'Seed data already present, skipping.'
  end
" 2>/dev/null || true

echo "==> Starting: $@"
exec "$@"
