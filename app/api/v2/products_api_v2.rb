require 'grape'
require 'entities_v2'

require_relative 'helpers/session_helpers'
require_relative 'helpers/product_helpers'
require_relative 'helpers/paging_helpers'


module V2
  class  ProductsApiV2 < Grape::API

    helpers ProductHelpers
    helpers SessionHelpers
    helpers PagingHelpers

    resource :products do

      before do
        track_apikey
      end


      desc "search packages", {
        notes: %q[

                This resource returns same results as our web application. But you get it as JSON objects -
                the result is an JSON array of product objects.

                When there's no match for the query, the result array will be empty.
              ]
      }
      params do
        requires :q, :type => String, :desc => "Query string. At least 2 characters."
        optional :lang, :type => String,
                        :desc => %q[Filter results by programming languages;
                                  For filtering multiple languages submit a comma separated list of language strings.
                                ]
        optional :g, :type => String, :desc => "Filter by GroupID. This is Java/Maven specific"
        optional :page, :type => Integer, :desc => "Specify page for paging", :regexp => /^[\d]+$/
      end
      get '/search/:q' do
        query    = parse_query(params[:q])
        group_id = params[:g]
        lang     = get_language_param(params[:lang])
        page_nr  = params[:page]
        page_nr  = nil if page_nr.to_i < 1 #will_paginate can't handle 0
        if query.length < 2
          error! "Search term was too short.", 400
        end

        languages = get_language_array(lang)

        start_time     = Time.now
        search_results = ProductService.search(query, group_id, languages, page_nr)

        save_search_log(query, search_results, start_time)
        query_data     = Api.new query: query, group_id: group_id, languages: languages
        paging         = make_paging_object(search_results)
        search_results = Api.new query: query_data, paging: paging, entries: search_results.entries

        present search_results, with: EntitiesV2::ProductSearchEntity
      end


      desc "detailed information for specific package", {
        notes: %q[

                  Please replace all slashes `/` through colons `:` and all dots `.` through `~`!

                  Example: The clojure package `yummy.json/json` has to be transformed to  `yummy~json:json`.

                  #### Notes about status codes

                    * API returns 404, when the product with given product key doesnt exists.

                    * Response 302 means that you didnt encode prod_key correctly.* (Replace all dots & slashes ) *
              ]
      }
      params do
        requires :lang, :type => String, :desc => %Q["Name of programming language"]
        requires :prod_key, :type => String,
                            :regexp => /[\w|:|~|-|\.]+/,
                            :desc => %Q["Encoded product key, replace all `/` and `.`]
      end
      get '/:lang/:prod_key' do
        product = fetch_product(params[:lang], params[:prod_key])

        if product.nil?
          error_msg = "No such package for #{params[:lang]} with product key: `#{params[:prod_key]}`."
          error! error_msg, 404
        end

        present product, with: EntitiesV2::ProductEntityDetailed
      end


      desc "check your following status", {
        notes: %q[
                  Please replace all slashes `/` through colons `:` and all dots `.` through `~`!

                  Example: The clojure package `yummy.json/json` has to be transformed to  `yummy~json:json`.

                  #### Notes about status codes

                  It will respond with 404, when given product with given product doesnt exists.
              ]
      }
      params do
        requires :lang, :type => String, :desc => %Q["Name of programming language"]
        requires :prod_key, :type => String, :desc => "Package specifier"
      end
      get '/:lang/:prod_key/follow' do
        authorized?
        current_product = fetch_product(params[:lang], params[:prod_key])
        if current_product.nil?
          error! "Wrong product_key", 400
        end

        user_follow = UserFollow.new
        user_follow.username = @current_user.username
        user_follow.prod_key = current_product.prod_key
        if @current_user.products
          user_follow.follows  = @current_user.products.include? current_product
        else
          user_follow.follows = false
        end

        present user_follow, with: EntitiesV2::UserFollowEntity
      end


      desc "follow your favorite software package", {
        notes: %q[

                  Please replace all slashes `/` through colons `:` and all dots `.` through `~`!

                  Example: The clojure package `yummy.json/json` has to be transformed to  `yummy~json:json`.

                  #### Notes about status codes

                  It will respond 404, when you are using wrong product key or encode it uncorrectly.
              ]
        }
      params do
        requires :lang, :type => String, :desc => %Q[Programming language]
        requires :prod_key, :type => String,
                            :desc => %Q{ Package product key. }
      end
      post '/:lang/:prod_key/follow' do
        authorized?
        current_product = fetch_product(params[:lang], params[:prod_key])
        if current_product.nil?
          error! "Wrong product_key", 400
        end

        current_product.users = Array.new if current_product.users.nil?
        unless current_product.users.include? @current_user
          current_product.users.push @current_user
          current_product.followers += 1
          current_product.save
        end

        user_follow = UserFollow.new
        user_follow.username = @current_user.username
        user_follow.prod_key = current_product.prod_key
        user_follow.follows  = current_product.users.include? @current_user

        present user_follow, with: EntitiesV2::UserFollowEntity
      end


      desc "unfollow given software package", {
        notes: %Q[
          Please replace all slashes `/` through colons `:` and all dots `.` through `~`!

          Example: The clojure package `yummy.json/json` has to be transformed to  `yummy~json:json`.

          #### Response codes

            * 400 - bad request; you used wrong product key;
            * 401 - unauthorized - please append api_key
            * 403 - forbidden; you are not authorized; or just missed api_key;
        ]
      }
      params do
        requires :lang, :type => String, :desc => %Q{Programming language}
        requires :prod_key, :type => String, :desc => "Package specifier"
      end
      delete '/:lang/:prod_key/follow' do
        authorized?
        @current_user = current_user
        current_product = fetch_product(params[:lang], params[:prod_key])
        error!("Wrong product key", 400) if current_product.nil?

        current_product.users = Array.new if current_product.users.nil?
        if current_product.users.include? @current_user
          current_product.users.delete @current_user
          current_product.followers -= 1
          current_product.save
        end

        user_follow = UserFollow.new
        user_follow.username = @current_user.username
        user_follow.prod_key = current_product.prod_key
        user_follow.follows  = @current_user.products.include? current_product

        present user_follow, with: EntitiesV2::UserFollowEntity
      end


      desc "references", {
        notes: %q[
                It returns the references of a package.

                Please replace all slashes `/` through colons `:` and all dots `.` through `~`!

                Example: The clojure package `yummy.json/json` has to be transformed to  `yummy~json:json`.
              ]
      }
      params do
        requires :lang, :type => String, :desc => "Language"
        requires :prod_key, :type => String, :desc => "Product Key"
        optional :page, :type => Integer, :desc => "Page for paging", :regexp => /^[\d]+$/
      end
      get '/:lang/:prod_key/references' do
        language = get_language_param(params[:lang])
        prod_key = params[:prod_key].to_s.downcase
        page     = params[:page]
        page     = 1 if page.to_i < 1

        product   = fetch_product language, prod_key
        if product.nil?
          error! "No package for `#{params[:lang]}`/`#{params[:prod_key]}`", 404
        end

        response = Dependency.references product.language, product.prod_key, page
        if response[:prod_keys].nil? || response[:prod_keys].empty?
          error! "Zero references for `#{params[:lang]}`/`#{params[:prod_key]}`", 404
        end

        products    = Product.by_prod_keys product.language, response[:prod_keys]
        total_count = response[:count]

        query_data = Api.new lang: language, prod_key: prod_key
        paging     = make_paging_for_references( page, total_count )
        results    = Api.new query: query_data, paging: paging, entries: products

        present results, with: EntitiesV2::ProductReferenceEntity
      end

    end # resource products

  end # class

end # end module
