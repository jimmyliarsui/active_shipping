module ActiveShipping

  class SF < Carrier
    
    cattr_accessor :default_options
    cattr_reader :name
    
    @@name = "SF"
    TEST_URL = 'http://bspoisp.sit.sf-express.com:11080/bsp-oisp/ws/sfexpressService?wsdl'
    LIVE_URL = 'https://bspoisp.sit.sf-express.com:11443/bsp-oisp/ws/sfexpressService?wsdl'


    def create_shipment(origin, destination, packages, options = {})
      options = @options.merge(options)
      request_body = build_shipment_request(origin, destination, packages, options)
      response = commit(request_body)
    end

    def find_tracking_info(tracking_number, options = {})
      options = @options.merge(options)
      request_body = build_query_request(tracking_number, options)
      response = commit(request_body)
    end
    
    
    protected

    def build_shipment_request(origin, destination, packages, options)
      xml_builder = Nokogiri::XML::Builder.new do |xml|
        xml.Body do
          xml.Order do
          end
        end
      end
    end


    def build_query_request(tracking_number, options = {})
      xml_builder = Nokogiri::XML::Builder.new do |xml|
        xml.Body do
          xml.RouteRequest do
            xml.tracking_type('1')
            xml.method_type('1')
            xml.tracking_number(tracking_number)
          end
        end
      end
    end
    
    def commit request_body
      
    end
  end
end

