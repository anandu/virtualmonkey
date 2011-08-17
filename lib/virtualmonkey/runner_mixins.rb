# Auto-require
some_not_included = true
files = Dir.glob(File.join(File.dirname(__FILE__), "runner_mixins", "**"))
retry_loop = 0
while some_not_included and retry_loop < (files.size ** 2) do
  begin
    some_not_included = false
    for f in files do
      some_not_included ||= require f.chomp(".rb") if f =~ /\.rb$/
    end
  rescue NameError => e
    raise e unless e.message =~ /uninitialized constant/i
    some_not_included = true
    files.push(files.shift)
  end
  retry_loop += 1
end
