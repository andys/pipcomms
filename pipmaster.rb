require 'net/http'
require 'uri'
require 'concurrent'

$temp = nil

@status = []
@posts = []
@commands = []

Thread.new do
	loop do
		sleep 5
		begin
			IO.popen("sudo ./temper -l5 -c", "r+") do |f|
				loop do
					f.flush
					temp = f.gets.chomp
					temp = temp.to_f rescue 0
					temp = nil unless temp > 0
					$temp = temp
				end
			end
		rescue Exception => e
                        puts e
                        puts e.backtrace.join("\n -> ")
		end
		$temp = nil
	end
end

Thread.new do
	loop do
		sleep 1
		begin
			IO.popen("sudo ./pip", "r+") do |f|
				loop do
					if(cmd = @commands.shift)
						response = ''
						while(response !~ /ACK/)
							puts "CMD:-> #{cmd.inspect}"
							f.puts cmd
							f.flush
							response = f.gets.chomp
							puts "    <- #{response.inspect}"
							sleep 0.2
						end
					end
					sleep 0.8
					f.puts "QPIGS"
					f.flush
					line = f.gets.chomp
					puts(f.read_nonblock(1024)) rescue nil
					if line !~ /^[0-9]/
						puts line
						next
					end
					fields = line.split(" ")
					status = {
						time: Time.now.to_f.round(1),
						grid_v: fields[0].to_f,
						grid_hz: fields[1].to_f,
						ac_v: fields[2].to_f,
						ac_hz: fields[3].to_f,
						ac_va: fields[4].to_i,
						ac_w: fields[5].to_i,
						load_pct: fields[6].to_i,
						bus_v: fields[7].to_i,
						bat_v: fields[8].to_f,
						bat_charge_a: fields[9].to_f,
						bat_cap_pct: fields[10].to_i,
						heatsink_temp: fields[11].to_i,
						pv_a: fields[12].to_i,
						pv_v: fields[13].to_f,
						bat_charge_v: fields[14].to_f,
						bat_discharge_a: fields[15].to_i
					}
					status[:pv_w] = (status[:pv_a] * status[:bat_charge_v]).round(0)
					status[:cell_v] = (status[:bat_v] / 16.0).round(2)
					status[:bat_w_charge] = (status[:ac_w] - status[:pv_w]).round(0)
					status[:bat_w_discharge] = ((status[:bat_discharge_a].to_f * status[:bat_v]) - (status[:bat_charge_a].to_f * status[:bat_charge_v])).round(0)
					status[:temp] = $temp if $temp
					@status << status
				end
			end
		rescue Exception => e
			puts e
			puts e.backtrace.join("\n -> ")
		end
	end
end

Thread.new do
	lastlength = 0
	loop {
		if((latest=@status.last) && lastlength != @status.length)
			lastlength = @status.length
			
			if lastlength > 1
				hours =  (@status[-1][:time] - @status[-2][:time]) / 3600.0
			end
			
			puts latest.to_s
		end
		sleep 0.3
	}
end

class Array
	def sum
		inject(0) {|memo, obj| memo + obj }
	end
	def avg
		sum.to_f / length.to_f
	end
	def field(fieldname)
		map {|h| h[fieldname] }.compact
	end
end


Thread.new do
	loop do
		begin
			sleep 10
			last_readings = @status[-20..-1]
			if last_readings && last_readings.length==20
				avg_volt = last_readings.field(:bat_charge_v).avg
				watts = last_readings.field(:bat_w_charge).avg
				watts = watts < 0 ? -watts : 0
				avg_amps = watts / avg_volt
				puts "battery charge state:  avg_volt=#{avg_volt.round(2)} avg_amps=#{avg_amps.round(2)}"
				if avg_volt >= 56.05 && avg_amps <= 10.0
					puts "Charge completion detected!"
					@commands << 'PBFT53.9'
					sleep 60
				end
			end
	        rescue Exception => e
	                puts e
	                puts e.backtrace.join("\n -> ")
	        end
	end
end

def post(array)
	#hours = (array.last[:time] - array.first[:time]) / 3600.0
	#$lifetime_wh += avg_pv_w * hours
	timestamp = Time.at(array.first[:time])
	v7 = array.field(:bat_w_charge).avg.round
	v8 = array.field(:bat_w_discharge).avg.round
	if(v8 > 0)
		v7 = 0
	else
		v7 = -v7
		v8 = 0
	end
	data = {
		'd' => timestamp.strftime('%Y%m%d'),
		't' => timestamp.strftime('%R'),
#		'c1' => 1, # cumulative/lifetime
#		'v1' => $lifetime_wh.round,
		'v2' => array.field(:pv_w).avg.round(1),
		'v4' => array.field(:ac_w).avg.round(1),
		'v5' => array.field(:temp).avg.round(1),
		'v6' => array.field(:pv_v).avg.round(1),
		'v7' => v7,
		'v8' => v8,
		'v9' => array.field(:bat_v).min.round(1),
		'v10'=> array.field(:bat_v).max.round(1)
	}
	puts data
	authdata = { 'X-Pvoutput-Apikey' => 'c30eccc114b0acd3821cb48cb0028befac9bd459', 'X-Pvoutput-SystemId' => '48029' }
	uri = URI('http://pvoutput.org/service/r2/addstatus.jsp')
	Net::HTTP.start(uri.host, uri.port) do |http|
		puts http.request_post(uri.path, URI.encode_www_form(data), authdata)
	end
end


interval = 300

loop do
	sleep(1 + interval - (Time.now.to_i % interval))
	begin
		datalist = []
		datalist << @status.shift until(@status.empty?)
		post(datalist)
		
	rescue Exception => e
		 puts e
		puts e.backtrace.join("\n -> ")
	end
end
