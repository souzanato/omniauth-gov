# lib/omniauth/strategies/gov.rb
require 'omniauth-oauth2'
require "uri"

module OmniAuth
  module Strategies
    class Gov < OmniAuth::Strategies::OAuth2
      option :name, 'gov'
      option :pkce, true

      credentials do
        hash = {"access_token" => access_token.token}
        hash["id_token"] = access_token.params["id_token"]
        hash["refresh_token"] = access_token.refresh_token if access_token.expires? && access_token.refresh_token
        hash["expires_at"] = access_token.expires_at if access_token.expires?
        hash["expires"] = access_token.expires?        
        hash
      end

      info do
        prune!({
          "id": raw_info['auth_time'],
          "cpf": raw_info["sub"],
          "nome_social": raw_info["social_name"],
          "email_verified": raw_info["email_verified"],
          "profile": raw_info["profile"],
          "username": raw_info["preferred_username"],
          "picture": raw_info["picture"],
          "name": raw_info["name"],
          "email": raw_info["email"],
        })
      end

      uid { raw_info['auth_time'] }

      extra do
        {
          'raw_info': raw_info
        }
      end

      def client
        options.client_options.merge!({connection_opts: {request: {params_encoder: GovBr::ParamsEncoder}}})
        ::OAuth2::Client.new(options.client_id, options.client_secret, deep_symbolize(options.client_options))
      end
      
      def request_phase
        redirect client.auth_code.authorize_url({:redirect_uri => callback_url}.merge(authorize_params))
      end 

      def raw_info
        @raw_info ||= JWT.decode(credentials["id_token"], nil, false)[0]
      end

      def prune!(hash)
        hash.delete_if do |_, value|
          prune!(value) if value.is_a?(Hash)
          value.nil? || (value.respond_to?(:empty?) && value.empty?)
        end
      end

      def authorize_params # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        options.authorize_params[:state] = SecureRandom.hex(24)
        options.authorize_params[:client_id] = options[:client_id]
        options.authorize_params[:scope] = options[:scope]
        options.authorize_params[:response_type] = 'code'
        options.authorize_params[:nonce] = SecureRandom.hex[0..11]
        params = options.authorize_params
          .merge(options_for("authorize"))
          .merge(pkce_authorize_params)

        session["omniauth.pkce.verifier"] = options.pkce_verifier if options.pkce
        session["omniauth.state"] = params[:state]

        params
      end   

      def callback_url
        full_host = OmniAuth.config.full_host
        callback_path = options.callback_path
        normalize_url(full_host+callback_path)
      end

      def normalize_url(url, force_https: true, strip_trailing_slash: true)
        url = url.strip

        # Adiciona protocolo se não existir
        url = "http://#{url}" unless url =~ %r{^https?://}i

        begin
          uri = URI.parse(url)

          # Força HTTPS se habilitado
          uri.scheme = force_https ? "https" : (uri.scheme || "http")

          # Normaliza host
          uri.host = uri.host.downcase if uri.host

          # Normaliza path:
          if uri.path
            # Troca // repetidos por /
            uri.path = uri.path.gsub(%r{/+}, "/")
            # Remove barra final se configurado (mas não no caso de root "/")
            if strip_trailing_slash && uri.path != "/" && uri.path.end_with?("/")
              uri.path = uri.path.chomp("/")
            end
          end

          # Ordena query params (se houver)
          if uri.query
            query_params = URI.decode_www_form(uri.query).uniq.sort
            uri.query = URI.encode_www_form(query_params)
          end

          uri.to_s
        rescue URI::InvalidURIError
          nil
        end
      end

      def build_access_token
        verifier = request.params["code"]
        
        atoken = client.auth_code.get_token(
          verifier, 
          {"grant_type": "authorization_code", "code": verifier, "redirect_uri": callback_url, "code_verifier": session["omniauth.pkce.verifier"]}, 
          {"Content-Type"  => "application/x-www-form-urlencoded", "Authorization" => "Basic #{Base64.strict_encode64(options.client_id+":"+options.client_secret)}" })
        atoken
      end  
    end
  end
end

OmniAuth.config.add_camelization 'gov', 'Gov'