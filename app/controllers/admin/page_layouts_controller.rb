# frozen_string_literal: true

class Admin::PageLayoutsController < AdminController
  helper_method :layout_options, :index_params
  before_action :set_defaults

  protected

  def set_defaults
    @show_again_on_save = true
  end

  def layout_options
    [['Master Panel', 'master'], ['User Profile', 'user_profile'], ['Dashboard / Page', 'standalone'],
     ['Panel View', 'view'], ['Navigation', 'nav']]
  end

  def default_index_order
    Arel.sql 'disabled asc nulls first, app_type_id asc, layout_name asc, panel_position asc'
  end

  def filters_on
    %i[layout_name app_type_id]
  end

  def filters
    {
      layout_name: Admin::PageLayout.active.pluck(:layout_name).uniq,
      app_type_id: Admin::AppType.all_by_name
    }
  end

  def permitted_params
    %i[app_type_id layout_name panel_name panel_label panel_position description options disabled]
  end

  def index_params
    permitted_params + %i[admin_id] - %i[disabled options]
  end
end
