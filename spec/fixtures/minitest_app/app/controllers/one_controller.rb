# frozen_string_literal: true

require_relative "../concerns/authable"
require_relative "../models/player"

class OneController
  include Authable

  def index
    authenticate
    Player.new("aron").fn_one
  end

  def render_view
    player = Player.new("aron")
    template = File.read(File.expand_path("../views/player.erb", __dir__))
    require "erb"
    ERB.new(template).result(binding)
  end
end
