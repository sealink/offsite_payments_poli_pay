# Requirements from:
# https://polipayments.com/assets/docs/POLiWebServicesMIG.pdf

module OffsitePayments
  module Integrations
    module PoliPay
      def self.notification(post, options = {})
        Notification.new(post, options)
      end

      def self.return(query_string, options = {})
        Return.new(query_string, options)
      end

      def self.sign(fields, key)
        OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA256.new, key, fields.sort.join)
      end

      class Interface
        include ActiveUtils::PostsData # ssl_get/post

        def self.base_url
          "https://poliapi.apac.paywithpoli.com/api"
        end

        def initialize(login, password)
          @login = login
          @password = password
        end

        private

        def standard_headers
          authorization = Base64.encode64("#{@login}:#{@password}")
          {
            'Content-Type' => 'application/json',
            'Authorization' => "Basic #{authorization}"
          }
        end

        def parse_response(raw_response)
          JSON.parse(raw_response)
        end

        class RequestError < StandardError
          attr_reader :exception, :message, :error_message, :error_code

          def initialize(exception)
            @exception = exception

            @response      = JSON.parse(exception.response.body)
            @success       = @response['Success']
            @message       = @response['Message']
            @error_message = @response['ErrorMessage']
            @error_code    = @response['ErrorCode']
          end

          def success?
            !!@success
          end

          def errors
            fail NotImplementedError, "This method must be implemented on the subclass"
          end

          def error_code_text
            errors[@error_code.to_s]
          end
        end
      end

      class UrlInterface < Interface
        def self.url
          "#{base_url}/Transaction/Initiate"
        end

        def call(options)
          raw_response = ssl_post(self.class.url, options.to_json, standard_headers)
          result = parse_response(raw_response)
          result['NavigateURL']
        rescue ActiveUtils::ResponseError => e
          raise UrlRequestError, e
        end

        class UrlRequestError < RequestError
          ERRORS = {
            '14050' => "A transaction-specific error has occurred",
            '14053' => "The amount specified exceeds the individual transaction limit set by the merchant",
            '14054' => "The amount specified will cause the daily transaction limit to be exceeded",
            '14055' => "General failure to initiate a transaction",
            '14056' => "Error in merchant-defined data",
            '14057' => "One or more values specified have failed a validation check",
            '14058' => "The monetary amount specified is invalid",
            '14059' => "A URL provided for one or more fields was not formatted correctly",
            '14060' => "The currency code supplied is not supported by POLi or the specific merchant",
            '14061' => "The MerchantReference field contains invalid characters",
            '14062' => "One or more fields that are mandatory did not have values specified",
            '14099' => "An unexpected error has occurred within transaction functionality"
          }

          def errors
            ERRORS
          end
        end
      end

      class QueryInterface < Interface
        def self.url(token)
          "#{base_url}/Transaction/GetTransaction?token=#{CGI.escape(token)}"
        end

        def call(token)
          raise ArgumentError, "Token must be specified" if token.blank?
          raw_response = ssl_get(self.class.url(token), standard_headers)
          parse_response(raw_response)
        rescue ActiveUtils::ResponseError => e
          raise QueryRequestError, e
        end

        class QueryRequestError < RequestError
          ERRORS = {
            '14050' => "Transaction was initiated by another merchant or another transaction-based error",
            '14051' => "The transaction was not found",
            '14052' => "The token provided was incomplete, corrupted or doesn't exist"
          }

          def errors
            ERRORS
          end
        end
      end

      class FinancialInstitutionsInterface < Interface
        def self.url
          "#{base_url}/Entity/GetFinancialInstitutions"
        end

        def call
          raw_response = ssl_get(self.class.url, standard_headers)
          result = parse_response(raw_response)
          result.map { |attr| FinancialInstitution.new(attr) }
        end
      end

      class Helper < OffsitePayments::Helper
        SUPPORTED_CURRENCIES = %w[AUD NZD]

        mapping :notify_url, 'NotificationUrl'
        mapping :amount, 'Amount'
        mapping :currency, 'CurrencyCode'
        mapping :order, 'MerchantReference'

        attr_reader :token_parameters

        def initialize(order, account, options = {})
          @login    = account
          @password = options.fetch(:password)
          @options  = options.except(:password).merge(order: order)
          check_order!(order)
          super(order, account, options.except(
            :homepage_url, :failure_url, :cancellation_url, :password))
          add_field 'MerchantDateTime', current_time_utc
          add_field 'Timeout', options[:timeout] if options[:timeout] # or defaults
          add_field 'SuccessUrl', options.fetch(:success_url) { options.fetch(:return_url) }
          add_field 'FailureUrl', options.fetch(:failure_url) { options.fetch(:return_url) }
          add_field 'CancellationUrl', options.fetch(:cancellation_url) { options.fetch(:return_url) }
          add_field 'MerchantHomepageURL', options.fetch(:homepage_url)
        end

        def check_order!(order)
          invalid = order.match /[^[[:alnum:]]_.:?\/\-|]/
          return unless invalid
          fail ArgumentError,
               'order not valid format, must only include alphanumeric, ' \
               'underscore (_), period (.), colon (:), question mark (?), ' \
               'forward slash (/), hyphen (-) or pipe (|)'
        end

        def current_time_utc
          Time.current.utc.strftime("%Y-%m-%dT%H:%M:%S")
        end

        def currency(symbol)
          unless SUPPORTED_CURRENCIES.include?(symbol)
            raise ArgumentError, "Unsupported currency"
          end
          add_field mappings[:currency], symbol
        end

        def amount(money)
          add_field mappings[:amount], '%.2f' % money.to_f.round(2)
        end

        def credential_based_url
          UrlInterface.new(@login, @password).call(form_fields)
        end
      end

      # See
      # http://www.polipaymentdeveloper.com/gettransaction#gettransaction_response
      class Notification < OffsitePayments::Notification
        def initialize(params, options = {})
          # POLi nudge uses Token, redirect use token
          token = params.fetch('Token') { params.fetch('token') }
          @params = QueryInterface.new(options[:login], options[:password]).call(token)
        end

        def acknowledge
          true # always valid as we fetch direct from poli
        end

        def complete?
          @params['TransactionStatusCode'] == 'Completed'
        end

        def success?
          complete? && gross && gross > 0
        end

        def gross
          @params['AmountPaid']
        end

        def currency
          @params['CurrencyCode']
        end

        def order_id
          @params['MerchantReference']
        end

        def transaction_id
          @params['TransactionRefNo']
        end

        # There is only a message on failure
        # http://www.polipaymentdeveloper.com/initiate#initiatetransaction_response
        def message
          @params['ErrorMessage']
        end
      end

      class Return < OffsitePayments::Return
        def initialize(query_string, options={})
          @notification = Notification.new(query_string, options)
        end
      end

      # See
      # http://www.polipaymentdeveloper.com/ficode#getfinancialinstitutions_response
      class FinancialInstitution
        attr_reader :name, :code

        def initialize(attr)
           @name   = attr.fetch('Name')
           @code   = attr.fetch('Code')
           @online = attr.fetch('Online')
        end

        def online?
          !!@online
        end
      end
    end
  end
end
