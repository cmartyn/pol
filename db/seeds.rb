# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

# Phase 6: the single editor account /admin is gated behind. This is a
# single-editor site (no roles, no invitations) — "idempotently ensure one
# editor User" is read literally: if ANY user already exists, this is a
# no-op, full stop, rather than matching on email so a later credentials
# change can't ever spawn a second account by re-running seeds.
#
# Password precedence: credentials, then ENV, then a generated one. A
# generated password is printed ONCE, on the run that creates the user, and
# never again — there is no other record of it anywhere, so losing that
# terminal output means resetting via `bin/rails runner` or the (unbuilt)
# forgot-password flow. A supplied password (credentials/ENV) is never
# echoed here — whoever set it already has it.
if User.exists?
  puts "db/seeds.rb: an admin user already exists — skipping."
else
  email = Rails.application.credentials.dig(:admin, :email) || "cmartyn@gmail.com"
  supplied_password = Rails.application.credentials.dig(:admin, :password) || ENV["ADMIN_PASSWORD"]
  generated = supplied_password.nil?
  password = supplied_password || SecureRandom.alphanumeric(24)

  User.create!(email_address: email, password: password)

  if generated
    puts "=" * 72
    puts "Created admin user #{email} with a GENERATED password:"
    puts ""
    puts "    #{password}"
    puts ""
    puts "This prints ONCE — it is not stored anywhere else. Save it now,"
    puts "then sign in at /session/new and consider setting credentials"
    puts "admin.password (or ADMIN_PASSWORD) so future environments don't"
    puts "need this generated path at all."
    puts "=" * 72
  else
    puts "Created admin user #{email} (password from credentials/ENV — not printed)."
  end
end
