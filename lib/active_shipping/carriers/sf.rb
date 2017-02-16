module ActiveShipping
  class SF < Carrier
    require 'httparty'

    self.retry_safe = true
    cattr_reader :name

    @@name = "SF"

    TEST_URL = "http://bspoisp.sit.sf-express.com:11080/bsp-oisp/sfexpressService"
    LIVE_URL = "not implemented"

    def requirements
      [:monthly_account, :checkword]
    end

    def create_shipment(origin, destination, packages, options={})
      order_hash = {
        orderid: options[:order_id],
        j_company: origin.company,
        j_contact: origin.name,
        j_tel: origin.phone,
        j_mobile: origin.mobile,
        j_province: origin.province,
        j_city: origin.city,
        j_county: origin.district,
        j_address: origin.address1,
        d_company: destination.company,
        d_contact: destination.name,
        d_tel: destination.phone,
        d_mobile: destination.mobile,
        d_province: destination.province,
        d_city: destination.city,
        d_county: destination.district,
        d_address: destination.address1,
        express_type: options[:service_code] || '1',
        parcel_quantity: options[:parcel_quantity] || 1,
        cargo_length: options[:cargo_length].to_s,
        cargo_width: options[:cargo_width].to_s,
        cargo_height: options[:cargo_height].to_s,
        j_post_code: options[:j_post_code].to_s,
        d_post_code: options[:d_post_code].to_s,
        pay_method: '1',
        is_gen_bill_no: '1',
        custid: @options[:monthly_account],
        remark: options['remark'].to_s
      }
      
      ## 对于跨境物流，这几个字段必要
      packages = packages.map{|pack|
        { name: pack.get_attr("name"),
          count: pack.get_attr("count"),
          unit: pack.get_attr("unit"),
          weight: pack.get_attr("weight"),
          amount: pack.get_attr("amount"),
          currency: pack.get_attr("currency"),
          source_area: pack.get_attr("source_area") }
      }

      packages_attr_str = packages.map{|pack| "<Cargo #{to_attr_str pack}> </Cargo>"}.join("\n")
      
      service_attr = []
      if options[:pay_value].present?
        ## 代收货款服务，value 为代收的钱，币种为人民币或者港币，根据寄货所在的地区 value1为收款卡号，保留3位小数。
        service_attr << { name: 'COD', value: options[:pay_value], value1: options[:payto_card_no]}
      end
      if options[:msg_number].present?
        ## 签收短信通知
        service_attr << { name: 'MSG', value: options[:msg_number] }
      end
      if options[:declared_value].present?
        #保价服务， value为声明价值以原寄地所在区域币种 为准，如中国大陆为人民币，香港为港币，保留3位小数。
        service_attr << { name: 'INSURE', value: options[:declared_value] }
      end

      if options[:delivery_date].present?
        service_attr << { name: 'TDELIVERY', value: options[:delivery_date], value1: options[:delivery_time_range] }
      end
      
      service_attr_str = if service_attr.size > 0
                           service_attr.map{|attr| "<AddedService #{to_attr_str attr} ></AddedService>"}.join("\n")
                         else
                           ""
                         end
      body = "<Order #{to_attr_str order_hash}> \n #{packages_attr_str}\n #{service_attr_str} \n</Order>"
      response = call_sf :OrderService, body, options[:test]
      parse_ship_response response
    end

    ## 查询发货单相关信息
    def find_tracking_info tracking_number, options = {}
      hash = { tracking_number: tracking_number, tracking_type: 1, method_type: 1 }
      body = "<RouteRequest #{to_attr_str hash} />"
      response = call_sf :RouteService, body, options[:test]
      parse_tracking_response response, tracking_number
    end

    # 客户在发货前取消订单。
    # 注意:订单取消之后,订单号也是不能重复利用的。
    def cancel_shipment tracking_number, options = {}
      hash = { orderid: options[:orderid], mailno: tracking_number, dealtype: 2}
      body = "<OrderConfirm #{to_attr_str hash}> </OrderConfirm>"
      response = call_sf :OrderConfirmService, body, options[:test]
      
    end

    # 客户在确定将货物交付给顺丰托运后,将运单上的一些重要信息,如快件重量通过 此接口发送给顺丰。
    # weight 重量
    # volume 为 长,宽,高
    def confirm orderid, tracking_number, weight, volume
      hash = { orderid: orderid, mailno: tracking_number, weight: weight, volume: volume, dealtype: 1}
      #hash = { orderid: '23322111', mailno: '444825172510', weight: 10, volume: '10,20,30', dealtype: 1}
      body = "<OrderConfirm #{to_attr_str hash}> </OrderConfirm>"
      call_sf :OrderConfirmService, body
    end

    protected

    def call_sf method, body, test = true
      params = "<Request service=\"#{method.to_s}\" lang=\"zh-CN\">
               <Head>BSPdevelop</Head>
               <Body>#{body}</Body>
              </Request>"

      verify_code = Base64.encode64(Digest::MD5.digest(params + @options[:checkword]))

      url = test ? TEST_URL : LIVE_URL
      res = HTTParty.post(url, { body: { xml: params, verifyCode: verify_code }})
      raise "顺丰接口返回空值" if !res.body.present?
      Hash.from_xml(res.body)["Response"]
    end

    def to_attr_str hash
      hash.map{|k, v| "#{k} = \"#{v}\""}.join("\n")
    end

    def parse_ship_response response
      success = response["Head"] == "OK"
      message = response["ERROR"].to_s
      track_no = success ? response["Body"]["OrderResponse"]["mailno"] : ""
      ## 顺丰需要自己渲染发货标签
      labels = track_no.split(",").map{|tr| Label.new(tr, "") }
      LabelResponse.new(success, message, response, {labels: labels})
    end

    def parse_tracking_response response, tracking_number
      success = response["Head"] == "OK"
      message = response["ERROR"].to_s
      shipment_events = []
      ship_status = ""
      if success && response["Body"].present?
        nodes = response["Body"]["RouteResponse"]["Route"]
        nodes = [nodes] if !nodes.is_a?(Array)
        shipment_events = nodes.map do |node|
          description = node["remark"]
          type_code = node["opcode"]
          zoneless_time = Time.parse(node["accept_time"])
          location = node["accept_address"]
          ShipmentEvent.new(description, zoneless_time, location, description, type_code)
        end
        if nodes.any?{|node| node["remark"].index("已签收").present? && node["opcode"].to_i == 80 }
          ship_status = :delivered
        end
      end
      TrackingResponse.new(success, message, response,
                           :carrier => @@name,
                           :xml => response,
                           :status => ship_status,
                           :request => last_request,
                           :shipment_events => shipment_events,
                           :tracking_number => tracking_number)
    end

  end
end
