#!/usr/bin/env ruby
require 'erb'
require 'httpi'
require 'optparse'
require 'tempfile'
require 'time'
require 'xml'

# global log function
$logfile = "/usr/local/var/log/connect_vbms.log"
def log(msg)
  log = File.open($logfile, 'a')
  log.write("#{Time.now.utc.iso8601}: #{msg}")
  log.write("\n")
end

# needs to happen before we change directories
$filedir = File.dirname(File.absolute_path(__FILE__))
def rel(name)
  File.join($filedir, name)
end

# return open file relative to this file's current directory
def openrel(name, mode='r')
  File.open(rel(name), mode)
end

def sh(cmd, ignore_errors=false)
  cmd.gsub! "\n", " \\\n"
  log(cmd)
  puts cmd
  out = `#{cmd}`
  if $? != 0 && !ignore_errors
    puts out
    puts cmd
    log("*** command failed: #{out}")
    raise "command failed"
  end
  out
end

# Given an env name (like "test", "uat", "pre") go get the appropriate environment
# variables and make them relative to this file. Return an env hash.
def getenv(envname)
  envdir = File.join(ENV["CONNECT_VBMS_ENV_DIR"], envname)

  env = {}
  env[:url] = ENV.fetch("CONNECT_VBMS_URL", nil)
  env[:keyfile] = ENV.fetch("CONNECT_VBMS_KEYFILE", nil)
  env[:saml] = ENV.fetch("CONNECT_VBMS_SAML", nil)
  env[:key] = ENV.fetch("CONNECT_VBMS_KEY", nil)
  env[:keypass] = ENV.fetch("CONNECT_VBMS_KEYPASS", nil)
  env[:cacert] = ENV.fetch("CONNECT_VBMS_CACERT", nil)
  env[:cert] = ENV.fetch("CONNECT_VBMS_CERT", nil)

  [:keyfile, :saml, :key, :cacert, :cert].each do |k|
    env[k] = File.absolute_path(File.join(envdir, env[k])) if env[k]
  end

  env
end

# prepare XML for document upload
# call UploadDocumentWithAssociations
# send XML, get response
# check response for error
# decrypt response
# return decrypted message
def upload_doc(options)
  begin
    # Because I don't know how to run a java file from another directory, we
    # have to actually change directory into the directory containing this
    # file. FML
    Dir.chdir(File.dirname(File.expand_path(__FILE__)))
    env = getenv(options[:env])
    log("Connecting with env: #{env}")
    file = prepare_xml(options[:pdf], options[:file_number], options[:received_dt], options[:first_name], options[:middle_name], options[:last_name], options[:exam_name])
    encrypted_xml = prepare_upload(file, env)
    response = send_document(encrypted_xml, env, options[:pdf])
    #handle_response(response)
  rescue Exception => e
    puts e.backtrace
    log(e.backtrace)
    puts e.message
    log(e.message)
    File.open("/tmp/signed.xml", 'w').write(encrypted_xml)
  ensure
    file.close
    file.unlink
  end
end

def write_tempfile(data, name="temp")
  file = Tempfile.new(name)
  file.write(data)
  file.close
  file
end

def get_tempname(name="temp")
  file = Tempfile.new(name)
  path = file.path
  file.close
  file.unlink
  path
end

def prepare_xml(pdf, file_number, received_dt, first_name, middle_name, last_name, subject)
  #what ought to go in these variables?
  externalId = "123"
  filename = File.split(pdf)[1]

  # Mary Kate Alber told us via email that the doctype should be "C&P Exam",
  # and a getDocumentTypes call shows this as the proper docType
  docType = "356"

  # There is no docs on the time format. Guessing based on examples from the
  # soapui project that it's GMT, 24 hour clock YYYY-MM-DD-HH:MM. Discovered
  # through trial and error that it doesn't allow a 24 hour clock, so the time
  # of day field is utterly useless. Insane. Is it actually supposed to be
  # GMT: who knows?
  time = Time.iso8601(received_dt)
  receivedDt = time.strftime "%Y-%m-%dZ"

  source = "VHA_CUI"

  # TODO: true if the claim associated with this evaluation is still pending,
  # false otherwise
  newMail = "true"

  template = openrel("upload_document_xml_template.xml.erb").read
  xml = ERB.new(template).result(binding)
  log("Unencrypted XML:\n#{xml}")

  write_tempfile(xml)
end

def prepare_upload(xmlfile, env)
  sh "java -classpath '.:../lib/*' UploadDocumentWithAssociations #{xmlfile.path} #{env[:keyfile]} #{env[:keypass]}"
end

def inject_saml(doc, env)
  log("parsing #{env[:saml]}")
  saml = doc.import(XML::Parser.file(env[:saml]).parse.root)
  wsse = "wsse:http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
  doc.find_first("//wsse:Security", wsse) << saml
end

def remove_mustUnderstand(doc)
  wsse = "wsse:http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
  doc.find_first("//wsse:Security", wsse).attributes.get_attribute("mustUnderstand").remove!
end

def build_request(url, data, headers, key: nil, keypass: nil, cert: nil, cacert: nil)
  request = HTTPI::Request.new(url)

  if key
    log("Auth\nkey: #{key}\ncert: #{cert}\nca_cert: #{cacert}")
    request.auth.ssl.cert_key_file     = key
    request.auth.ssl.cert_key_password = keypass
    request.auth.ssl.cert_file         = cert
    request.auth.ssl.ca_cert_file      = cacert
    request.auth.ssl.verify_mode       = :peer
  else
    log("No Auth")
    request.auth.ssl.verify_mode = :none
  end

  request.body = data

  request.headers = headers
  request
end

def send_document(xml, env, pdf)
  # inject SAML header
  doc = XML::Parser.string(xml).parse
  inject_saml(doc, env)
  remove_mustUnderstand(doc)
  xml = doc.to_s
  File.open("/tmp/final.xml", 'w').write(xml)
  filename = File.split(pdf)[1]
  pdf = IO.read(pdf)

  req = ERB.new(openrel("mtom_request.erb").read).result(binding)
  headers = {
    'Content-Type' => 'Multipart/Related; type="application/xop+xml"; start-info="application/soap+xml"; boundary="boundary_1234"'
  }

  # for the rest, grab the cert and ca
  if env[:cacert]
    key = env[:key]
    keypass = env[:keypass]
    cert = env[:cert]
    cacert = env[:cacert]
  else
    key = keypass = cert = cacert = nil
  end

  request = build_request(env[:url], req, headers, key: key, keypass: keypass, cert: cert, cacert: cacert)
  begin
    response = HTTPI.post(request)
  rescue => e
    puts e.class
  end
  log("response code: #{response.code}")
  log("response headers: #{response.headers}")
  log("response body: #{response.body}")

  response.body
end

def get_soap(txt)
  soap = txt.match(/<soap:envelope.*?<\/soap:envelope>/im)[0]
  XML::Parser.string(soap).parse
end

def handle_response(response)
  doc = get_soap(response)
  log("Response from VBMS:\n#{doc.to_s}")

  soap = "http://schemas.xmlsoap.org/soap/envelope/"
  if doc.find_first("//soap:Fault", soap)
    $stderr.write("Received error from VBMS:\n#{soap.to_s}\nCheck logfile in #{$logfile}")
    exit
  end

  file = write_tempfile(soap.to_s)

  # now here's the hackiest thing in the world. This command is going to fail,
  # because we can't get the signatures to properly get decrypted. So run the
  # command, handle the error, and pull the message out of the file >:|
  sh "java -classpath '.:../lib/*' DecryptMessage", true

end

def parse(args)
  usage = "Usage: send.rb --pdf <filename> --env <env> --file_number <n> --received_dt <dt> --first_name <name> --middle_name [<name>] --last_name <name> --logfile [<file>] "
  options = {}

  parser = OptionParser.new do |opts|
    opts.banner = usage

    opts.on("--pdf <filename>", "PDF file to upload") do |v|
      options[:pdf] = v
    end

    opts.on("--file_number <n>", "File number") do |v|
      options[:file_number] = v
    end

    opts.on("--received_dt <dt>", "Time in iso8601 GMT") do |t|
      options[:received_dt] = t
    end

    opts.on("--first_name <name>", "Veteran first name") do |n|
      options[:first_name] = n
    end

    opts.on("--middle_name [<name>]", "Veteran middle name") do |n|
      options[:middle_name] = n
    end

    opts.on("--last_name <name>", "Veteran last name") do |n|
      options[:last_name] = n
    end

    opts.on("--exam_name <name>", "Name of the exam being sent") do |n|
      options[:exam_name] = n
    end

    opts.on("--env [env]", "Environment to use: test, UAT, ...") do |v|
      options[:env] = v
    end

    opts.on("--logfile [logfile]", "Logfile to use. Defaults to /usr/local/var/log/connect_vbms.log") do |v|
      $logfile = v
    end
  end

  parser.parse!

  required_options = [:env, :file_number, :pdf, :received_dt, :first_name, :last_name, :exam_name]
  if !required_options.map{|opt| options.has_key? opt}.all?
    puts "missing keys #{required_options.select{|opt| !options.has_key? opt}}"
    puts parser.help
    exit
  end

  options
end

options = parse(ARGV)
upload_doc(options)
