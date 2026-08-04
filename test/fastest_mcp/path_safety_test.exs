defmodule FastestMCP.PathSafetyTest do
  use ExUnit.Case, async: true

  alias FastestMCP.PathSafety

  @moduletag :tmp_dir

  test "realpath resolves a finite path that revisits a symlink", %{tmp_dir: tmp_dir} do
    base = PathSafety.realpath!(tmp_dir)
    actual = Path.join(base, "actual")
    logical = Path.join(base, "logical")
    root = Path.join(actual, "root")
    file = Path.join(root, "file.txt")

    File.mkdir_p!(root)
    File.write!(file, "safe")
    File.ln_s!(actual, logical)
    File.ln_s!(Path.join(logical, "root"), Path.join(root, "back"))

    assert {:ok, ^root} = PathSafety.realpath(Path.join([logical, "root", "back"]))
    assert {:ok, ^file} = PathSafety.realpath(Path.join([logical, "root", "back", "file.txt"]))
  end

  test "realpath rejects an actual symlink cycle", %{tmp_dir: tmp_dir} do
    base = PathSafety.realpath!(tmp_dir)
    first = Path.join(base, "first")
    second = Path.join(base, "second")

    File.ln_s!(second, first)
    File.ln_s!(first, second)

    assert {:error, :eloop} = PathSafety.realpath(first)
  end

  test "realpath bounds a symlink cycle whose resolver state keeps expanding", %{
    tmp_dir: tmp_dir
  } do
    base = PathSafety.realpath!(tmp_dir)
    path = Path.join(base, "expanding")

    File.ln_s!(Path.join(path, "next"), path)

    assert {:error, :eloop} = PathSafety.realpath(path)
  end
end
