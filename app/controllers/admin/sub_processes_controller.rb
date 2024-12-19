class Admin::SubProcessesController < AdminController
  include AdminControllerHandler
  before_action :set_protocol, only: %i[index new show edit]
  before_action :set_protocol_for_edit, only: %i[create update]
  def index
    set_objects_instance(@sub_processes = @protocol.sub_processes)
    response_to_index
  end

  def new(options = {})
    set_object_instance(@sub_process = @protocol.sub_processes.build) unless options[:use_current_object]
    render partial: 'form'
  end

  private

  def title
    'Sub Processes'
  end

  def sub_title
    "Protocol: #{@protocol.name}"
  end

  def view_folder
    'admin/common_templates'
  end

  def admin_links(item = nil)
    return [true] unless item&.id

    [
      ['edit events', admin_protocol_sub_process_protocol_events_path(@protocol, item)]
    ]
  end

  def set_protocol
    protocol_id = params[:protocol_id] || object_instance.protocol_id
    @protocol = Classification::Protocol.find(protocol_id)
    @parent_param = { protocol_id: @protocol.id }
  end

  def set_protocol_for_edit
    protocol_id = secure_params[:protocol_id] || object_instance.protocol_id
    @protocol = Classification::Protocol.find(protocol_id)
    @parent_param = { protocol_id: @protocol.id }
  end

  def permitted_params
    %i[name disabled protocol_id]
  end
end
