require 'net/http'
require 'uri'
require 'concurrent'
require 'json'

$temp = nil
$bms = {}
$lastbms = 0
CAPACITY_AH = 160

FLOAT_V = '53.7'

@status = []
@bms_status = []
@posts = []
$fastcharge = true

@user_commands = []
@commands = []


Thread.new do
	loop do
		sleep 5
		begin
                        device = Dir['/dev/ttyACM*'].first
			IO.popen("sudo ./usbtin #{device}", "r+") do |f|
				loop do
					#f.flush
					# CAN message { id = 0x1f4  len = 8 [ 00 33 10 02 8c 7f 15 00]}
					#if canmsg =~ /CAN message { id = 0x1f4 .* \[ ([0-9af][0-9af]) ([0-9af][0-9af]) ([0-9af][0-9af]) ([0-9af][0-9af]) ([0-9af][0-9af]) ([0-9af][0-9af]) ([0-9af][0-9af]) ([0-9af][0-9af])\]}/
					#"bms_temp":40, "bms_v":129.6, "bms_a":3250.4, "bms_errors":0, "soc":"99%"}
					canmsg = f.gets
					canmsg.chomp! if canmsg
					if canmsg =~ /^t1F48([0-9A-F]{2})([0-9A-F]{2})([0-9A-F]{2})([0-9A-F]{2})([0-9A-F]{2})([0-9A-F]{2})([0-9A-F]{2})/
						bms = {
							time: Time.now.to_f.round(1),
							bms_errors: $1.to_i(16),
							soc: $2.to_i(16),
							bms_v: ($4+$3).to_i(16) * 0.1,
							bms_a: (($6+$5).to_i(16) - 32768) * 0.1,
							bms_temp: $7.to_i(16)
						}
						$bms = bms if $bms.empty?
						bms.delete(:bms_temp) if bms[:bms_temp] >= 80 || bms[:bms_temp] <= 0
						if bms[:bms_errors] > 0
							puts "!! WARNING !!  got bms_error = #{bms[:bms_errors]}"
						elsif(bms[:soc] - $bms[:soc]).abs > 2 ||
						  (bms[:bms_v] >= 70) || (bms[:bms_v] < 40) ||
						  (bms[:bms_a] >= 1000) || (bms[:bms_a] < -1000) ||
						  (bms[:soc] > 100)
							puts "Ignoring nonsensical BMS values: #{bms.to_json}\n  previous = #{$bms.to_json}"
						else
							$bms = bms
							$lastbms = Time.now.to_i
							@bms_status << bms
						end
					end
				end
			end
		rescue Exception => e
                        puts e
                        puts e.backtrace.join("\n -> ")
		end
	end
end

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
		sleep 3
		begin
			device = Dir['/dev/ttyUSB*'].first
			IO.popen("sudo ./pip #{device}", "r+") do |f|
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
					if(cmd = @user_commands.shift)
						response = ''
						puts "CMD:-> #{cmd.inspect}"
						f.puts cmd
						f.flush
						response = f.gets.chomp
						puts "    <- #{response.inspect}"
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
						#bat_cap_pct: fields[10].to_i, # useless field
						heatsink_temp: fields[11].to_i,
						pv_a: fields[12].to_i,
						pv_v: fields[13].to_f,
						bat_charge_v: fields[14].to_f,
						bat_discharge_a: fields[15].to_i
					}
					status[:pv_w] = (status[:pv_a] * status[:bat_charge_v]).round(0)
					status[:cell_v] = (status[:bat_v] / 16.0).round(2)
					status[:bat_w_charge] = if status[:grid_v] > 1
							-(status[:bat_charge_a].to_f * status[:bat_charge_v].to_f).round(0)
						else
							(status[:ac_w] - status[:pv_w]).round(0)
						end
					status[:bat_w_discharge] = ((status[:bat_discharge_a].to_f * status[:bat_v]) - (status[:bat_charge_a].to_f * status[:bat_charge_v])).round(0)
					status[:temp] = $temp if $temp
					status[:bms_temp] = $bms[:bms_temp] if $bms[:bms_temp]
					status[:bms_v] = $bms[:bms_v].round(1) if $bms[:bms_v]
					status[:bms_a] = $bms[:bms_a].round(1) if $bms[:bms_a]
					status[:bms_errors] = $bms[:bms_errors] if $bms[:bms_errors]
					status[:soc] = "#{$bms[:soc]}%" if $bms[:soc]
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
			
			puts latest.to_json.gsub(/,/, ', ')
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
	def median
		sort[length.div(2)]
	end
	def without_outlier(m = max)
		self.select {|f| f.abs <= m }
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
				puts "PIP: avg_volt=#{avg_volt.round(1)} avg_amps=#{avg_amps.round(1)}"
				if avg_volt >= 56.05 && avg_amps <= 10.0
					puts "Charge completion detected (PIP)!"
					$fastcharge = false
					@commands << "PBFT#{FLOAT_V}"
					sleep 60
				end
			end
			if(Time.now.to_i - $lastbms > 10)
				$bms = {}
			end
			last_readings = @bms_status[-70..-1]
			if last_readings && last_readings.length==70
				med_volt = last_readings.field(:bms_v).without_outlier(63.0).median
				med_amps = -last_readings.field(:bms_a).without_outlier(300.0).median
				avg_amps = -last_readings.field(:bms_a).without_outlier(med_amps.abs * 2).avg
				if med_amps > 0
					puts "BMS: med_volt=#{med_volt.round(1)} avg_amps=#{avg_amps.round(1)} med_amps=#{med_amps.round(1)}"
					if med_volt >= 56.00 && med_amps <= 9.0
						puts "Charge completion detected (BMS)!"
						@commands << "PBFT#{FLOAT_V}"
						$fastcharge = false
						sleep 60
					end
				end
				soc = last_readings.field(:soc).without_outlier(100.1).median
				if soc
					required_ah = ((100.0 - soc) / 100.0) * CAPACITY_AH.to_f

					ttf = if avg_amps.to_i == 0
						0.0
					else
						required_ah / avg_amps.to_f
					end

					puts "BMS: SoC=#{soc} fastcharge=#{$fastcharge.inspect} required=#{(required_ah * 0.053).round(1)}kWh eta=#{Time.at(Time.now.to_f + ttf * 3600.0).strftime('%H:%M')}"
					#if soc >= 98 && $fastcharge
					#	puts "Charge completion detected (SoC)!"
					#	@commands << 'PBFT53.7'
					#	$fastcharge = false
					#	sleep 60
					#els
					if soc <= 95 && !$fastcharge
						puts "SoC dropped - reinstating fast charge mode!"
						@commands << 'PBFT56.1'
						$fastcharge = true
						sleep 60
					end
				end
			end
			if Time.now.hour == 0 && Time.now.min == 0
				puts "Midnight detected - resetting"
				$fastcharge = true
				@commands << 'PBFT56.1'
				sleep 60
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
		'v9' => @bms_status.field(:bms_v).without_outlier(63.0).median.round(1),
		'v10'=> @bms_status.field(:soc).without_outlier(100.1).median,
		'v11'=> @bms_status.field(:bms_temp).without_outlier(80.0).median.round(1),
		'v12'=> @bms_status.field(:errors).max
	}
	puts data
	authdata = { 'X-Pvoutput-Apikey' => 'c30eccc114b0acd3821cb48cb0028befac9bd459', 'X-Pvoutput-SystemId' => '48029' }
	uri = URI('http://pvoutput.org/service/r2/addstatus.jsp')
	Net::HTTP.start(uri.host, uri.port) do |http|
		puts http.request_post(uri.path, URI.encode_www_form(data), authdata)
	end
end


interval = 300

Thread.new do
	loop do
		sleep(1 + interval - (Time.now.to_i % interval))
		begin
			datalist = []
			datalist << @status.shift until(@status.empty?)
			post(datalist)
			@bms_status = @bms_status[-50..-1]
		rescue Exception => e
			 puts e
			puts e.backtrace.join("\n -> ")
		end
	end
end

loop do
	input = $stdin.gets.chomp
	if input =~ /^Q.+/ || input =~ /^P.+/ || input =~ /^M.+/
		@user_commands << input
	end
	input = nil
end
