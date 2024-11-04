import string
import re
import mqtt
import json

def log(msg)
    tasmota.log('SMR: ' + str(msg))
end

def bufFindRev(buf, needle)
    var i = buf.size() - 1
    while i >= 0
        if buf[i] == needle
            return i
        end
        i -= 1
    end
    return -1
end

def readTextFile(file)
    var f = open(file, "r")
    var data = f.read()
    f.close()
    return data
end

var lastHappy = 0
def happyTasmota()
    if tasmota.millis() - lastHappy > 50
        tasmota.yield()
        lastHappy = tasmota.millis()
    end
end

def crc16(data, crc, len)
    var di = 0
    while di < len
        crc ^= data[di]
        var i = 0
        while i < 8
            if crc & 0x0001
                crc = (crc >> 1) ^ 0xa001
            else
                crc >>= 1
            end
            i += 1
        end
        di += 1
    end
    return crc
end

class stats
    var depth, stack, pos, cnt

    def init(depth)
        self.depth = depth
        self.stack = bytes()
        self.stack.resize(depth)
        self.pos = 0
        self.cnt = 0
    end

    def push(val)
        self.stack[self.pos] = val ? 1 : 0
        self.pos = (self.pos + 1) % self.depth
        self.cnt += 1
    end

    def getQuality()
        if self.cnt < self.depth return -1 end
        var sum = 0
        for i: 0 .. self.depth - 1
            sum += self.stack[i]
        end
        return sum * 100 / self.depth
    end

end

class smr
    var config, telegram, rules, ser, crc, wireCrc, payloadAvailable, wireStats
    var sensors, dataAvailable
    var reCode, reNum, reStr

    # Sample rule fragment:
    # 1,1-0:32.7.0(@1,Voltage,V,voltage_l1,17
    # 1,0-0:1.0.0(@#),Time,time,time,0

    def init()
        self.config = nil
        self.telegram = nil
        self.rules = {}
        self.crc = nil
        self.wireCrc = nil
        self.payloadAvailable = false
        self.sensors = {}
        self.dataAvailable = false

        self.reCode = re.compile('^([0-9]-[0-9]:[0-9]+\\.[0-9]+\\.[0-9]+)(\\([^)]+\\))')
        self.reNum = re.compile('^\\((-?[0-9.]+)[*)]')
        self.reStr = re.compile('^\\(([^)]*)\\)')

        self.config = json.load(readTextFile('smr-config.json'))
        self.config['tasmotaTopic'] = string.replace(string.replace(
            tasmota.cmd('FullTopic', true)['FullTopic'],
            '%topic%', tasmota.cmd('Topic', true)['Topic']),
            '%prefix%', tasmota.cmd('Prefix', true)['Prefix3']) + 'SENSOR'
    
        self.wireStats = stats(self.config['statDepth'])
        var cf = readTextFile(self.config['rulesConf'])

        var cfRules = string.split(cf, "\n")
        for rule: cfRules
            if size(rule) == 0 continue end
            var parts = string.split(rule, ',')
            if parts.size() < 6 || parts[0] < '1' || parts[0] > '9' continue end
            var codeDesc = string.split(parts[1], '(')
            var code = codeDesc[0]
            var vType = 0  # number
            if size(codeDesc[1]) > 1 && codeDesc[1][1] == '#'
                vType = 1  # string
            end
            # obis_code = metric_description, unit, metric_name, vType
            self.rules[code] = [parts[2], parts[3], parts[4], vType]
            self.sensors[parts[4]] = [code, nil]
            happyTasmota()
        end

        self.ser = serial(self.config['serialRx'], self.config['serialTx'], self.config['serialBaud'], serial.SERIAL_8N1, true)
        self.ser.flush()
        tasmota.add_fast_loop(/-> self.readTelegram())
    end

    def deinit()
        self.ser.close()
    end

    # Sample telegram fragment:
    # 1-0:8.8.0(000023.622*kvarh)
    # 1-0:15.8.0(000223.000*kWh)
    # 1-0:32.7.0(237.2*V)
    # 1-0:31.7.0(002*A)
    # 0-0:96.13.0()
    # !AB12

    def processPayload()
        if self.config['ignoreCrc']
            # do some cleanup only when CRC is ignored
            for i: 0 .. self.telegram.size() - 1
                var bb = self.telegram[i]
                if bb != 0x0d && bb != 0x0a && (bb < 0x20 || bb > 0x7f)
                    self.telegram[i] = 0x20
                end
            end
        end

        var obis = string.split(self.telegram.asstring(), '\r\n')
        var timeStr = tasmota.time_str(tasmota.rtc()['local'])

        for line: obis
            var m = self.reCode.match(line)
            if m == nil || m.size() < 3 continue end
            var code = m[1]
            var rule = self.rules.find(code)
            if rule == nil continue end
            m = rule[3] == 0 ? self.reNum.match(m[2]) : self.reStr.match(m[2])
            if m == nil || m.size() < 2 continue end
            var name = rule[2]
            var value = rule[3] == 1 ? m[1] : real(m[1])
            # log(format('code: %s, desc: %s, unit: %s, name: %s, value: %s', code, rule[0], rule[1], name, value))
            if self.config['tasmotaTele']
                # tele/ma105-meter/SENSOR = {"Time":"2024-10-25T19:06:56","ma105":{"energy_export":102.791}}
                var topic = self.config['tasmotaTopic']
                var q = rule[3] == 1 ? '"' : ''
                var payload = format('{"Time":"%s","%s":{"%s":%s}}', timeStr, self.config['meterName'], name, q + value + q)
                mqtt.publish(topic, payload)
            else
                # tele/ma105-meter/smr/energy_export = 102.791
                var topic = self.config['topic'] + name
                mqtt.publish(topic, format('%s', value))
            end
            self.sensors[name][1] = value
            happyTasmota()
        end
        self.dataAvailable = true
    end
    
    def readTelegram()
        if !self.ser.available() return end
        self.payloadAvailable = false
        var buf = self.ser.read()
        self.telegram = buf
        var t1 = tasmota.millis() + 25
        while !tasmota.time_reached(t1)
            while self.ser.available()
                buf = self.ser.read()
                self.telegram .. buf
                t1 = tasmota.millis() + 25
            end
        end
        self.ser.flush()
        self.payloadAvailable = true
    end

    def every_250ms()
        if !self.payloadAvailable || self.telegram == nil || self.telegram.size() == 0 return end

        var dtopic
        if self.config['debugTelegram']
            # do this before any processing
            dtopic = self.config['topic'] + 'telegram'
            var half = self.telegram.size() / 2
            mqtt.publish(dtopic + '1', self.telegram[0 .. half - 1].tohex())
            mqtt.publish(dtopic + '2', self.telegram[half ..].tohex())
        end

        var eotpos = bufFindRev(self.telegram, 0x21)  # '!'
        if self.telegram[0] != 0x2f || eotpos == -1 return end

        if self.config['ignoreCrc']
            self.processPayload()
            log('processed payload, CRC ignored')
        else
            self.wireCrc = string.toupper(self.telegram[eotpos + 1 .. eotpos + 4].asstring())
            self.crc = crc16(self.telegram, 0, eotpos + 1)
            self.crc = format('%04X', self.crc)
            if self.crc == self.wireCrc
                self.wireStats.push(true)
                self.processPayload()
                log('processed payload, CRC OK')
            else
                self.wireStats.push(false)
                log(format('payload CRC error, calculated CRC: %s, CRC on wire: %s', self.crc, self.wireCrc))
            end
        end
        self.payloadAvailable = false

        if self.config['debugTelegram']
            mqtt.publish(dtopic + '_meta', format('%d,%s,%s', self.telegram.size(), self.wireCrc, self.crc))
        end

        var wq = self.wireStats.getQuality()
        if !self.config['ignoreCrc'] && wq != -1
            if self.config['tasmotaTele']
                var topic = self.config['tasmotaTopic']
                var payload = format(
                    '{"Time":"%s","%s":{"%s":%d}}', tasmota.time_str(tasmota.rtc()['local']),
                    self.config['meterName'], 'wire_quality', wq)
                mqtt.publish(topic, payload)
            else
                var topic = self.config['topic'] + 'wire_quality'
                mqtt.publish(topic, format('%d', wq))
            end
        end

        self.crc = nil
        self.wireCrc = nil
        self.telegram = nil
    end

    def web_sensor()
        if self.config.find('webSensors') == nil || !self.dataAvailable return end
        var tmp = ''
        for name: self.config['webSensors']
            var value = self.sensors[name][1]
            var rule = self.rules[self.sensors[name][0]]
            var desc = rule[0]
            var unit = rule[1]
            tmp += format('{s}%s{m}%s %s{e}', desc, value, unit)
        end
        var wq = self.wireStats.getQuality()
        if wq != -1
            tmp += format('{s}Signal quality{m}%d %%{e}', wq)
        end
        tasmota.web_send_decimal(tmp)
    end

    def json_append()
        if self.config.find('teleperiodSensors') == nil return end
        var meterName = self.config['meterName']
        var fragMap = {}
        for name: self.config['teleperiodSensors']
            var value = self.dataAvailable ? self.sensors[name][1] : nil
            fragMap[name] = value
        end
        if !self.config['ignoreCrc']
            var wq = self.wireStats.getQuality()
            wq = wq == -1 ? nil : wq
            if wq != -1
                fragMap['wire_quality'] = wq
            end
        end
        var frag = ',' + json.dump({meterName: fragMap})[1 .. -2]
        tasmota.response_append(frag)
      end

end

smrDriver = smr()
tasmota.add_driver(smrDriver)
