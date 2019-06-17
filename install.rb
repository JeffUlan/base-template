gem "stripe"
gem "devise"
gem_group :development, :test do
  gem "dotenv-rails"
  gem "rubocop", "~> 0.71.0", require: false
end

after_bundle do

  # Setup
  current_path = File.expand_path(File.dirname(__FILE__))

  # DotEnv Gem setup
  matcher = "Bundler.require(*Rails.groups)\n"
  inject_into_file("config/application.rb", after: "#{matcher}") do
    <<~"HEREDOC"
      Dotenv::Railtie.load
    HEREDOC
  end

  # ENV stubs and populate
  run("touch .env")
  run("echo .env >> .gitignore")

  puts "\n\n"
  puts "=~" * 40

  puts "For details on how to find these keys go here:"
  puts "<INSERT LINK TO VISUAL INSTRUCTIONS>\n" #TODO: insert link to instructions

  stripe_test_secret_key = ask("What is your Stripe Test Secret Key?")
  stripe_test_publish_key = ask("What is your Stripe Test Publishable Key?")
  stripe_product_id = ask("What is your Stripe Product ID?")
  stripe_sku_id = ask("What is your Stripe SKU ID?")

  run("echo 'STRIPE_SECRET_KEY=#{stripe_test_secret_key}' >> .env")
  run("echo 'STRIPE_PUBLISHABLE_KEY=#{stripe_test_publish_key}' >> .env")
  run("echo 'STRIPE_PRODUCT_ID=#{stripe_product_id}' >> .env")
  run("echo 'STRIPE_SKU_ID=#{stripe_sku_id}' >> .env")

  puts "=~" * 40
  puts "\n\n"

  # Stripe payments
  initializer 'stripe.rb', <<-HEREDOC
    Stripe.api_key = ENV["STRIPE_SECRET_KEY"]
  HEREDOC

  # Devise authentication
  generate("devise:install")
  environment 'config.action_mailer.default_url_options = { host: "localhost", port: 3000 }', env: 'development'

  matcher = "class ApplicationController < ActionController::Base\n"
  inject_into_file("app/controllers/application_controller.rb", after: "#{matcher}") do
    <<~"HEREDOC"
      before_action :authenticate_user!
        
      def after_sign_in_path_for(resource_or_scope)
        stored_location_for(resource_or_scope) || dashboard_path
      end
    HEREDOC
  end

  # Devise users
  generate("devise User")
  generate("devise:views")

  path = "app/controllers/users"
  file = "registrations_controller.rb"
  run("mkdir -p #{path}")
  run("cp #{current_path}/../base-template/files/#{path}/#{file} #{path}/#{file}")

  path = "app/views/devise/registrations"
  file = "new.html.erb"
  run("rm #{path}/#{file}")
  run("cp #{current_path}/../base-template/files/#{path}/#{file} #{path}/#{file}")

  gsub_file 'config/routes.rb', "devise_for :users", ""
  route('devise_for :users, controllers: { registrations: "users/registrations" }')

  matcher = "end"
  inject_into_file("app/models/user.rb", before: "#{matcher}") do
    <<~"HEREDOC"
        
      def stripe_order(params)
        email = params[:user][:email]
        create_customer(params[:stripe_token], email)
        pay(email)
      end
    
      # TODO: Abstract remote API calls
      def create_customer(source, email)
        self.stripe_customer = Stripe::Customer.create(source: source, email: email).id
      rescue Stripe::CardError => e
        errors.add(:payment, e.json_body[:error][:message])
      end
    
      # TODO: Abstract remote API calls
      def pay(email)
        order = Stripe::Order.create(customer: self.stripe_customer, currency: 'usd', email: email, items: [{ type: 'sku', parent: (ENV['STRIPE_SKU_ID']).to_s, quantity: 1 }])
        self.stripe_status = order.status        
        self.stripe_order_id = order.id
        payment = Stripe::Order.pay(stripe_order_id, { customer: stripe_customer } )
        self.stripe_status = payment.status
      end

    HEREDOC
  end

  # Main site
  generate(:controller, "Home", "index")
  route "root to: 'home#index'"
  gsub_file 'config/routes.rb', "get 'home/index'", ""

  matcher = "<%= yield %>\n"
  inject_into_file("app/views/layouts/application.html.erb", after: "#{matcher}") do
    <<-HEREDOC
      <script src="https://js.stripe.com/v3/"></script>      
      <%= yield :javascript %>
    HEREDOC
  end

  matcher = "class HomeController < ApplicationController\n"
  inject_into_file("app/controllers/home_controller.rb", after: "#{matcher}") do
    <<~"HEREDOC"
      skip_before_action :authenticate_user!
    HEREDOC
  end

  # Member Dashboard
  generate(:controller, "Dashboard", "index")
  route "get :dashboard, to: 'dashboard#index'"
  gsub_file 'config/routes.rb', "get 'dashboard/index'", ""

  # Database
  generate(:migration, "AddStripeFieldsToUser stripe_customer:string:index stripe_order_id:string:index stripe_status:string")
  rails_command("db:migrate")

  # Rubocop
  rubocop_path = "#{current_path}/../base-template/files/.rubocop.yml"
  run("cp #{rubocop_path} ./.rubocop.yml")
  run("bundle exec rubocop -a")

  # Git
  git :init
  git add: "."
  git commit: %Q{ -m 'Initial commit generated via BoilerplateCode.com' }
end
