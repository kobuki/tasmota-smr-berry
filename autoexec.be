import string
import re
import mqtt
import json

def log(msg)
    tasmota.log('SMR: ' + str(msg))
end

def bufFind(buf, needle)
    for i: 0 .. buf.size() - 1
        if buf[i] == needle
            return i
        end
    end
    return -1
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
    for di: 0 .. len - 1
        crc ^= data[di]
        for i: 0 .. 7
            if crc & 0x0001
                crc = (crc >> 1) ^ 0xa001
            else
                crc >>= 1
            end
        end
        happyTasmota()
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

    # 1,1-0:32.7.0(@1,Voltage,V,voltage_l1,17
    # 1,0-0:1.0.0(@#),Time,time,time,0

    def init()
        self.config = nil
        self.telegram = nil
        self.rules = {}
        self.crc = nil
        self.payloadAvailable = false
        self.sensors = {}
        self.dataAvailable = false

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
        tasmota.add_fast_loop(/-> self.readTelegram())
    end

    def deinit()
        self.ser.close()
    end

    # 1-0:8.8.0(000023.622*kvarh)
    # 1-0:15.8.0(000223.000*kWh)
    # 1-0:32.7.0(237.2*V)
    # 1-0:31.7.0(002*A)
    # 0-0:96.13.0()
    # !AB12

    def processPayload()
        var obis = string.split(self.telegram.asstring(), '\r\n')
        var rr = re.compile('^([0-9]-[0-9]:[0-9]+\\.[0-9]+\\.[0-9]+)\\(([^*)]*)?[*)]([^()]+)?\\)?')
        var timeStr = tasmota.time_str(tasmota.rtc()['local'])

        for line: obis
            var m = rr.match(line)
            if m == nil || m.size() < 4 continue end
            var code = m[1]
            var rule = self.rules.find(code)
            if rule == nil continue end
            var name = rule[2]
            var value = rule[3] == 1 ? m[2] : real(m[2])
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
        var t1 = tasmota.millis() + 150
        while !tasmota.time_reached(t1)
            while self.ser.available()
                buf = self.ser.read()
                self.telegram .. buf
            end
        end
        self.ser.flush()
        self.payloadAvailable = true
    end

    def every_250ms()
        if !self.payloadAvailable return end

        var eotpos = bufFindRev(self.telegram, 0x21)  # '!'
        if eotpos == -1 return end

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
        self.payloadAvailable = false

        var wq = self.wireStats.getQuality()
        if wq == -1 return end
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

        if self.config['debugTelegram']
            var dtopic = self.config['topic'] + 'telegram'
            var half = self.telegram.size() / 2
            mqtt.publish(dtopic + '1', self.telegram[0 .. half - 1].tohex())
            mqtt.publish(dtopic + '2', self.telegram[half ..].tohex())
            mqtt.publish(dtopic + '_meta', format('%d,%s', self.telegram.size(), self.crc))
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
        if self.config.find('teleperiodSensors') == nil || !self.dataAvailable return end
        var meterName = self.config['meterName']
        var fragMap = {}
        for name: self.config['webSensors']
            var value = self.sensors[name][1]
            fragMap[name] = value
        end
        var wq = self.wireStats.getQuality()
        if wq != -1
            fragMap['wire_quality'] = wq
        end
        var frag = ',' + json.dump({meterName: fragMap})[1 .. -2]
        tasmota.response_append(frag)
      end

end

smrDriver = smr()
tasmota.add_driver(smrDriver)
