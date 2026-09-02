defmodule StillWebTest.SampleRouter do
  @moduledoc false
  use StillWeb, :router
end

defmodule StillWebTest.SampleController do
  @moduledoc false
  use StillWeb, :controller
end

defmodule StillWebTest.SampleComponent do
  @moduledoc false
  use StillWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"<div>{@id}</div>"
  end
end

defmodule StillWebTest.SampleHTML do
  @moduledoc false
  use StillWeb, :html

  def sample(assigns) do
    ~H"""
    <span>{~p"/"}</span>
    """
  end
end

defmodule StillWebTest do
  use ExUnit.Case, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest

  test ":router builds a Phoenix router" do
    assert StillWebTest.SampleRouter.__routes__() == []
  end

  test ":controller builds a plug" do
    assert function_exported?(StillWebTest.SampleController, :call, 2)
  end

  test ":live_component builds a live component" do
    assert StillWebTest.SampleComponent.__live__() == %{kind: :component, layout: false}
  end

  test ":html builds function components with verified routes" do
    assigns = %{}

    assert rendered_to_string(~H"<StillWebTest.SampleHTML.sample />") =~ "<span>/</span>"
  end
end
