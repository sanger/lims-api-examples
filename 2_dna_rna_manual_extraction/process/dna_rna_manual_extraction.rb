require 'helper/constant'
require 'rubygems'
require 'ruby-debug/debugger'

# This script goes through the different steps 
# of the DNA+RNA manual extraction pipeline.

module Lims::Api::Examples
  module DnaRnaManualExtraction    

    def self.included(klass)
      extend ClassMethods
    end

    module ClassMethods
      include Constant
      include Constant::DnaRnaManualExtraction

      def start
        workflow
      end

      def set_barcodes(barcodes = [])
        @barcodes = barcodes
        @init_tubes_number = barcodes.size
      end

      private

      def workflow
        # =======================================
        API::new_stage("Search the source tubes. Search the order. Assign a batch to the source tubes.")
        # =======================================

        # Find the tubes by barcodes
        parameters = {:search => {:description => "search for barcoded tube",
                                  :model => "tube",
                                  :criteria => {:label => {:position => "barcode",
                                                           :type => "sanger-barcode",
                                                           :value => @barcodes}}}}
        search_response = API::post("searches", parameters)
        result_url = search_response["search"]["actions"]["first"]
        result_response = API::get(result_url) 
        source_tube_uuids = result_response["tubes"].reduce([]) { |m,e| m << e["tube"]["uuid"] }

        # Find the order by tube uuid and role
        parameters = {:search => {:description => "search for order",
                                  :model => "order",
                                  :criteria => {:item => {:uuid => source_tube_uuids.first,
                                                          :role => ROLE_TUBE_TO_BE_EXTRACTED}}}}
        search_response = API::post("searches", parameters)
        result_url = search_response["search"]["actions"]["first"]
        result_response = API::get(result_url)
        order = result_response["orders"].first["order"]
        order_uuid = order["uuid"]

        # Check that no batch has been assigned to the tubes
        no_batch = order["items"][ROLE_TUBE_TO_BE_EXTRACTED].reduce(true) { |m,e| m = m && e["batch"].nil? }
        abort("Error: A batch is already assigned to the source tube") unless no_batch

        # Create a new batch
        parameters = {:batch => {}}
        response = API::post("batches", parameters)
        batch_uuid = response["batch"]["uuid"]

        # Assign the batch uuid to the tubes in the order item
        parameters = {:items => {ROLE_TUBE_TO_BE_EXTRACTED => {}.tap do |h|
          source_tube_uuids.each { |uuid| h.merge!({uuid => {:batch_uuid => batch_uuid}}) }
        end }}
        API::put(order_uuid, parameters)


        # =========================
        API::new_stage("Build and start the order")
        # =========================

        # Change the status of the order to pending
        parameters = {:event => :build}
        API::put(order_uuid, parameters)

        # Change the status of the order to in_progress
        parameters = {:event => :start}
        API::put(order_uuid, parameters)


        # ============================================
        API::new_stage("Create binding_spin_columns_dna spin columns. Create by_product_tube tubes.
Transfers from tube_to_be_extracted into binding_spin_column_dna and by_product_tube tubes.") 
        # ============================================

        # Create new spin columns
        binding_spin_column_dna_uuids = Array.new(@init_tubes_number).map do |_| 
          parameters = {:spin_column => {}}
          response = API::post("spin_columns", parameters)
          response["spin_column"]["uuid"]
        end

        # Create new tubes 
        by_product_tube_uuids = Array.new(@init_tubes_number).map do |_| 
          parameters = {:tube => {}}
          response = API::post("tubes", parameters)
          response["tube"]["uuid"]
        end

        # Add the new spin columns and new tubes in the order
        # and start each of them
        parameters = {:items => {}.tap do |h|
          [ROLE_BINDING_SPIN_COLUMN_DNA, ROLE_BY_PRODUCT_TUBE].zip([binding_spin_column_dna_uuids, by_product_tube_uuids]).each do |role, uuids|
            h.merge!({role => {}.tap { |h_uuid|
              uuids.each { |uuid| h_uuid.merge!({uuid => {:event => :start, :batch_uuid => batch_uuid}}) } 
            }})
          end
        end
        }
        API::put(order_uuid, parameters)

        # Transfers from tube_to_be_extracted into 
        # binding_spin_column_dna spins and into
        # by_product_tube tubes.
        parameters = {:transfer_tubes_to_tubes => {:transfers => [].tap do |a|
          source_tube_uuids.zip(binding_spin_column_dna_uuids).each do |source_uuid, target_uuid|
            a << {:source_uuid => source_uuid, :target_uuid => target_uuid, :fraction => 0.5, :aliquot_type => ALIQUOT_TYPE_DNA}
          end
          source_tube_uuids.zip(by_product_tube_uuids).each do |source_uuid, target_uuid|
            a << {:source_uuid => source_uuid, :target_uuid => target_uuid, :fraction => 0.5, :aliquot_type => ALIQUOT_TYPE_RNAP}
          end
        end
        }}
        API::post("actions/transfer_tubes_to_tubes", parameters)

        # Change the status of the binding_spin_column_dna to done
        # Change the status of the by_product_tube to done
        # Change the status of the tube_to_be_extracted to unused
        parameters = {:items => {}.tap do |h|
          [ROLE_BINDING_SPIN_COLUMN_DNA, ROLE_BY_PRODUCT_TUBE].zip([binding_spin_column_dna_uuids, by_product_tube_uuids]).each do |role, uuids|
            h.merge!({role => {}.tap { |h_uuid|
              uuids.each { |uuid| h_uuid.merge!({uuid => {:event => :complete}}) } 
            }})
          end
          h.merge!({ROLE_TUBE_TO_BE_EXTRACTED => {}.tap { |h_uuid|
            source_tube_uuids.each { |uuid| h_uuid.merge!({uuid => {:event => :unuse}}) }
          }})
        end
        }
        API::put(order_uuid, parameters)


        # ==============================================
        API::new_stage("Use the binding_spin_column_dna spins in a new role elution_spin_column_dna.
Then transfer the content of the spin columns to new extracted_tube tubes.")
        # ==============================================

        # Add the binding_spin_column_dna under the role 
        # elution_spin_column_dna and start them.
        elution_spin_column_dna_uuids = binding_spin_column_dna_uuids # alias
        parameters = {:items => {ROLE_ELUTION_SPIN_COLUMN_DNA => {}.tap { |h|
          elution_spin_column_dna_uuids.each { |uuid| h.merge!({uuid => {:event => :start, :batch_uuid => batch_uuid}}) }
        }}}
        API::put(order_uuid, parameters)

        # Change the status of elution_spin_column_dna to done
        # Change the status of binding_spin_column_dna to unused 
        parameters = {:items => {ROLE_ELUTION_SPIN_COLUMN_DNA => {}.tap { |h|
          elution_spin_column_dna_uuids.each { |uuid| h.merge!({uuid => {:event => :complete}}) }
        }, ROLE_BINDING_SPIN_COLUMN_DNA => {}.tap { |h|
          binding_spin_column_dna_uuids.each { |uuid| h.merge!({uuid => {:event => :unuse}}) }
        }}}
        API::put(order_uuid, parameters)

        # Create new tubes 
        extracted_tube_dna_uuids = Array.new(@init_tubes_number).map do |_| 
          parameters = {:tube => {}}
          response = API::post("tubes", parameters)
          response["tube"]["uuid"]
        end

        # Add the extracted_dna_tube in the order 
        # and start them
        parameters = {:items => {ROLE_EXTRACTED_TUBE => {}.tap { |h|
          extracted_tube_dna_uuids.each { |uuid| h.merge!({uuid => {:event => :start}}) }
        }}}
        API::put(order_uuid, parameters)

        # Transfer elution_spin_column_dna into extracted_tube
        parameters = {:transfer_tubes_to_tubes => {:transfers => [].tap { |a|
          elution_spin_column_dna_uuids.zip(extracted_tube_dna_uuids).each do |source_uuid, target_uuid|
            a << {:source_uuid => source_uuid, :target_uuid => target_uuid, :fraction => 1}
          end
        }}}
        API::post("actions/transfer_tubes_to_tubes", parameters)

        # Change the status of extracted_tube tubes to done
        # Change the status of elution_spin_column_dna to unused
        parameters = {:items => {ROLE_EXTRACTED_TUBE => {}.tap { |h|
          extracted_tube_dna_uuids.each { |uuid| h.merge!({uuid => {:event => :complete}}) }
        },
        ROLE_ELUTION_SPIN_COLUMN_DNA => {}.tap { |h|
          elution_spin_column_dna_uuids.each { |uuid| h.merge!({uuid => {:event => :unuse}}) }
        }}}
        API::put(order_uuid, parameters)


        # =====================================
        API::new_stage("Create new tube_to_be_extracted tube. Transfer from by_product_tube into tube_to_be_extracted.")
        # =====================================

        # Create new tubes 
        tube_to_be_extracted_uuids = Array.new(@init_tubes_number).map do |_| 
          parameters = {:tube => {}}
          response = API::post("tubes", parameters)
          response["tube"]["uuid"]
        end

        # Add tube_to_be_extracted tubes in the order and
        # start them.
        parameters = {:items => {ROLE_TUBE_TO_BE_EXTRACTED => {}.tap { |h|
          tube_to_be_extracted_uuids.each { |uuid| h.merge!({uuid => {:event => :start, :batch_uuid => batch_uuid}}) }
        }}}
        API::put(order_uuid, parameters)

        # Transfer from by_product_tube tubes into
        # tube_to_be_extracted tubes
        parameters = {:transfer_tubes_to_tubes => {:transfers => [].tap { |a|
          by_product_tube_uuids.zip(tube_to_be_extracted_uuids).each do |source_uuid, target_uuid|
            a << {:source_uuid => source_uuid, :target_uuid => target_uuid, :fraction => 1}
          end
        }}}
        API::post("actions/transfer_tubes_to_tubes", parameters)

        # Change the status of by_product_tube to done
        # Change the status of tube_to_be_extracted to done
        parameters = {:items => {ROLE_TUBE_TO_BE_EXTRACTED => {}.tap { |h|
          tube_to_be_extracted_uuids.each { |uuid| h.merge!({uuid => {:event => :complete}}) }
        },
        ROLE_BY_PRODUCT_TUBE => {}.tap { |h|
          by_product_tube_uuids.each { |uuid| h.merge!({uuid => {:event => :unuse}}) }
        }}}
        API::put(order_uuid, parameters)


        # =============================================
        API::new_stage("Create binding_spin_column_rna spins. Create by_product_tube tubes. 
Transfer tube_to_be_extracted into binding_spin_column_rna and into by_product_tube.")
        # =============================================

        # Create new spin columns
        binding_spin_column_rna_uuids = Array.new(@init_tubes_number).map do |_| 
          parameters = {:spin_column => {}}
          response = API::post("spin_columns", parameters)
          response["spin_column"]["uuid"]
        end

        # Create new tubes 
        by_product_tube_uuids = Array.new(@init_tubes_number).map do |_| 
          parameters = {:tube => {}}
          response = API::post("tubes", parameters)
          response["tube"]["uuid"]
        end

        # Add the new spin columns and new tubes in the order
        # and start each of them
        parameters = {:items => {}.tap do |h|
          [ROLE_BINDING_SPIN_COLUMN_RNA, ROLE_BY_PRODUCT_TUBE].zip([binding_spin_column_rna_uuids, by_product_tube_uuids]).each do |role, uuids|
            h.merge!({role => {}.tap { |h_uuid|
              uuids.each { |uuid| h_uuid.merge!({uuid => {:event => :start, :batch_uuid => batch_uuid}}) } 
            }})
          end
        end
        }
        API::put(order_uuid, parameters)

        # Transfers from tube_to_be_extracted into 
        # binding_spin_column_rna spins and into
        # by_product_tube tubes.
        parameters = {:transfer_tubes_to_tubes => {:transfers => [].tap do |a|
          tube_to_be_extracted_uuids.zip(binding_spin_column_rna_uuids).each do |source_uuid, target_uuid|
            a << {:source_uuid => source_uuid, :target_uuid => target_uuid, :fraction => 0.5, :aliquot_type => ALIQUOT_TYPE_RNA}
          end
          tube_to_be_extracted_uuids.zip(by_product_tube_uuids).each do |source_uuid, target_uuid|
            a << {:source_uuid => source_uuid, :target_uuid => target_uuid, :fraction => 0.5}
          end
        end
        }}
        API::post("actions/transfer_tubes_to_tubes", parameters)

        # Change the status of binding_spin_column_rna to done
        # Change the status of by_product_tube to done
        # Change the status of tube_to_be_extracted to unused
        parameters = {:items => {}.tap do |h|
          [ROLE_BINDING_SPIN_COLUMN_RNA, ROLE_BY_PRODUCT_TUBE].zip([binding_spin_column_rna_uuids, by_product_tube_uuids]).each do |role, uuids|
            h.merge!({role => {}.tap { |h_uuid|
              uuids.each { |uuid| h_uuid.merge!({uuid => {:event => :complete}}) } 
            }})
          end
          h.merge!({ROLE_TUBE_TO_BE_EXTRACTED => {}.tap { |h_uuid|
            tube_to_be_extracted_uuids.each { |uuid| h_uuid.merge!({uuid => {:event => :unuse}}) }
          }})
        end
        }
        API::put(order_uuid, parameters)


        # ==============================================
        API::new_stage("Use the binding_spin_column_rna spins in a new role elution_spin_column_rna.
Then transfer the content of the spin columns to new extracted_tube tubes.")
        # ==============================================

        # Add the binding_spin_column_rna under the role 
        # elution_spin_column_rna and start them.
        elution_spin_column_rna_uuids = binding_spin_column_rna_uuids # alias
        parameters = {:items => {ROLE_ELUTION_SPIN_COLUMN_RNA => {}.tap { |h|
          elution_spin_column_rna_uuids.each { |uuid| h.merge!({uuid => {:event => :start, :batch_uuid => batch_uuid}}) }
        }}}
        API::put(order_uuid, parameters)

        # Change the status of elution_spin_column_rna to done
        # Change the status of binding_spin_column_rna to unused 
        parameters = {:items => {ROLE_ELUTION_SPIN_COLUMN_RNA => {}.tap { |h|
          elution_spin_column_rna_uuids.each { |uuid| h.merge!({uuid => {:event => :complete}}) }
        }, ROLE_BINDING_SPIN_COLUMN_RNA => {}.tap { |h|
          binding_spin_column_rna_uuids.each { |uuid| h.merge!({uuid => {:event => :unuse}}) }
        }}}
        API::put(order_uuid, parameters)

        # Create new tubes 
        extracted_tube_rna_uuids = Array.new(@init_tubes_number).map do |_| 
          parameters = {:tube => {}}
          response = API::post("tubes", parameters)
          response["tube"]["uuid"]
        end

        # Add the extracted_rna_tube in the order 
        # and start them
        parameters = {:items => {ROLE_EXTRACTED_TUBE => {}.tap { |h|
          extracted_tube_rna_uuids.each { |uuid| h.merge!({uuid => {:event => :start}}) }
        }}}
        API::put(order_uuid, parameters)

        # Transfer elution_spin_column_rna into extracted_tube
        parameters = {:transfer_tubes_to_tubes => {:transfers => [].tap { |a|
          elution_spin_column_rna_uuids.zip(extracted_tube_rna_uuids).each do |source_uuid, target_uuid|
            a << {:source_uuid => source_uuid, :target_uuid => target_uuid, :fraction => 1}
          end
        }}}
        API::post("actions/transfer_tubes_to_tubes", parameters)

        # Change the status of extracted_tube tubes to done
        # Change the status of elution_spin_column_rna to unused
        parameters = {:items => {ROLE_EXTRACTED_TUBE => {}.tap { |h|
          extracted_tube_rna_uuids.each { |uuid| h.merge!({uuid => {:event => :complete}}) }
        },
        ROLE_ELUTION_SPIN_COLUMN_RNA => {}.tap { |h|
          elution_spin_column_rna_uuids.each { |uuid| h.merge!({uuid => {:event => :unuse}}) }
        }}}
        API::put(order_uuid, parameters)


        # ============================================
        API::new_stage("Change the status of the order to completed.")
        # ============================================

        parameters = {:event => :complete}
        API::put(order_uuid, parameters)
      end
    end
  end
end
