$:.push File.expand_path("../lib", __FILE__)

Gem::Specification.new do |s|
  s.platform     = Gem::Platform::RUBY
  s.name         = 'offsite_payments_poli_pay'
  s.version      = '1.0.1'
  s.date         = '2018-03-05'
  s.summary      = 'PoliPay integration for the activemerchant offsite_payments gem.'
  s.description  = 'This gem extends the activemerchant offsite_payments gem ' \
                   'providing integration of PoliPay.'
  s.license      = 'MIT'

  s.author = 'Stefan Cooper'
  s.email = 'stefan.cooper@sealink.com.au'
  s.homepage = 'https://github.com/sealink/offsite_payments_poli_pay'

  s.files = Dir['CHANGELOG', 'README.md', 'MIT-LICENSE', 'lib/**/*']
  s.require_path = 'lib'

  s.add_development_dependency('offsite_payments')
end
