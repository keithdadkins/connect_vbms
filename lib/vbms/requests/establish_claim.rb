module VBMS
  module Requests
    class EstablishClaim < BaseRequest
      NAMESPACES = {
        "xmlns:cla" => "http://vbms.vba.va.gov/external/ClaimService/v4",
        "xmlns:cdm" => "http://vbms.vba.va.gov/cdm/claim/v4",
        "xmlns:participant" => "http://vbms.vba.va.gov/cdm/participant/v4"
      }.freeze

      def initialize(veteran_record, claim)
        @veteran_record = veteran_record
        @claim = claim
      end

      def name
        "establishClaim"
      end

      def endpoint_url(base_url)
        "#{base_url}#{VBMS::ENDPOINTS[:claims]}"
      end

      def inject_header_content(header_xml)
        Nokogiri::XML::Builder.with(header_xml) do |xml|
          xml["vbmsext"].userId("dslogon.1011239249", "xmlns:vbmsext" => "http://vbms.vba.va.gov/external")
        end
      end

      # More information on what the fields mean, see:
      # https://github.com/department-of-veterans-affairs/dsva-vbms/issues/66#issuecomment-266098034
      def soap_doc
        VBMS::Requests.soap(more_namespaces: NAMESPACES) do |xml|
          xml["cla"].establishClaim do
            xml["cla"].veteranInput(
              "fileNumber" => @veteran_record[:file_number],
              "gender" => @veteran_record[:sex],
              "marriageStatus" => "Unknown"
            ) do
              xml["participant"].preferredName(
                "firstName" => @veteran_record[:first_name],
                "lastName" => @veteran_record[:last_name])

              xml["participant"].personalInfo("ssn" => @veteran_record[:ssn]) do
                xml["participant"].address(
                  "addressLine1" => @veteran_record[:address_line1],
                  "addressLine2" => @veteran_record[:address_line2],
                  "addressLine3" => @veteran_record[:address_line3],
                  "city" => @veteran_record[:city],
                  "stateCode" => @veteran_record[:state],
                  "countryCode" => @veteran_record[:country],
                  "postalCode" => @veteran_record[:zip_code],
                  "preferredAddr" => "true",
                  "type" => ""
                )
              end
            end

            xml["cla"].claimToEstablish(
              "benefitTypeCd" => @claim[:benefit_type_code], # C&P Live = '1', C&P Death = '2'
              "claimLevelStatusCd" => "PEND",
              "payeeCd" => @claim[:payee_code],
              "label" => @claim[:end_product_label],
              "modifiedEndProductCd" => @claim[:end_product_modifier],
              "sectionUnit" => "999", # This number doesn't matter, but is required
              "stationOfJurisdiction" => @claim[:station_of_jurisdiction],
              "currentStationOfJurisdiction" => @claim[:station_of_jurisdiction],
              "disposition" => "M",
              "folderWithClaim" => "N",
              "priority" => "1",
              "preDischarge" => @claim[:predischarge] ? "true" : "false",
              "gulfWarRegistry" => @claim[:gulf_war_registry] ? "true" : "false"
            ) do
              xml["cdm"].endProductClaimType(
                "code" => @claim[:end_product_code],
                "name" => @claim[:end_product_label]
              )

              xml["cdm"].claimDateDt @claim[:date].iso8601
              xml["cdm"].suppressAckLetter @claim[:suppress_acknowledgment_letter]
            end
          end
        end
      end

      def signed_elements
        [["/soapenv:Envelope/soapenv:Body",
          { soapenv: SoapScum::XMLNamespaces::SOAPENV },
          "Content"]]
      end

      def handle_response(doc)
        el = doc.at_xpath(
          "//claimV4:establishClaimResponse/claimV4:establishedClaim",
          VBMS::XML_NAMESPACES
        )

        VBMS::Responses::Claim.create_from_xml(el)
      end
    end
  end
end