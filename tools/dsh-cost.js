// DSH 花费计算：逐帧解压会话日志，按「每次请求的模型 + 时刻」折算人民币
// 用法：node dsh-cost.js <sessionsDir> <yyyy-MM-dd> [pricesJson]
// 输出：一行 JSON

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

// 元 / 百万 tokens（高峰价），空闲时段减半
const DEFAULT_PRICES = {
  "deepseek-flash": { hit: 0.04, miss: 2.0, out: 8.0 },
  "deepseek-v4-pro": { hit: 0.30, miss: 9.0, out: 27.0 },
  "deepseek-chat": { hit: 0.04, miss: 2.0, out: 8.0 },
  "deepseek-reasoner": { hit: 0.30, miss: 9.0, out: 27.0 },
};

function scanFrames(buf) {
  const frames = [];
  let i = 0;
  while (i + 4 <= buf.length) {
    if (!(buf[i] === 0x28 && buf[i + 1] === 0xB5 && buf[i + 2] === 0x2F && buf[i + 3] === 0xFD)) {
      i++;
      continue;
    }
    const start = i;
    i += 4;
    const fhd = buf[i++];
    const fcsFlag = fhd >> 6;
    const singleSegment = (fhd >> 5) & 1;
    const checksum = (fhd >> 2) & 1;
    const dictFlag = fhd & 3;
    if (!singleSegment) i += 1;
    i += [0, 1, 2, 4][dictFlag];
    i += [0, 2, 4, 8][fcsFlag];
    while (i + 3 <= buf.length) {
      const h = buf[i] | (buf[i + 1] << 8) | (buf[i + 2] << 16);
      i += 3;
      const last = h & 1;
      const type = (h >> 1) & 3;
      const size = h >>> 3;
      i += type === 1 ? 1 : size;
      if (last) break;
    }
    if (checksum) i += 4;
    frames.push([start, i]);
  }
  return frames;
}

// 高峰：周一至周五 9:00-12:00、14:00-18:00（北京时间）；其余为空闲（价格减半）
function isPeak(d) {
  const day = d.getDay();
  if (day === 0 || day === 6) return false;
  const h = d.getHours();
  return (h >= 9 && h < 12) || (h >= 14 && h < 18);
}

function localDateKey(d) {
  const p = (n) => String(n).padStart(2, "0");
  return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate());
}

function walk(dir, out) {
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (e) {
    return out;
  }
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) walk(full, out);
    else if (e.name.endsWith(".zstd")) out.push(full);
  }
  return out;
}

function main() {
  const sessionsDir = process.argv[2] || path.join(process.env.USERPROFILE || "", ".dsh", "sessions");
  const today = process.argv[3] || localDateKey(new Date());
  let prices = DEFAULT_PRICES;
  if (process.argv[4]) {
    try {
      const custom = JSON.parse(process.argv[4]);
      if (custom && typeof custom === "object") prices = Object.assign({}, DEFAULT_PRICES, custom);
    } catch (e) {}
  }

  const files = walk(sessionsDir, []).filter((f) => {
    try {
      return localDateKey(fs.statSync(f).mtime) === today;
    } catch (e) {
      return false;
    }
  });

  const stat = {
    cost: 0, peakCost: 0, offPeakCost: 0,
    inTokens: 0, outTokens: 0, cacheRead: 0, cacheWrite: 0,
    requests: 0, files: files.length,
    models: {},
  };

  for (const file of files) {
    let buf;
    try {
      buf = fs.readFileSync(file);
    } catch (e) {
      continue;
    }
    let model = "unknown";
    for (const [a, b] of scanFrames(buf)) {
      let text;
      try {
        text = zlib.zstdDecompressSync(buf.subarray(a, b)).toString("utf8");
      } catch (e) {
        continue;
      }
      for (const line of text.split("\n")) {
        if (!line.trim()) continue;
        let ev;
        try {
          ev = JSON.parse(line);
        } catch (e) {
          continue;
        }
        const t = ev.type;
        const data = ev.data || {};
        // 记住这次请求用的模型
        if (t === "request/header" && data.header && data.header.config && data.header.config.model) {
          model = String(data.header.config.model);
          continue;
        }
        if (t === "request/context" && data.model) {
          model = String(data.model);
          continue;
        }
        if (t !== "assistant/message" || !data.usage) continue;

        const when = new Date(Number(ev.time) || Date.now());
        if (localDateKey(when) !== today) continue;   // 只算今天的

        const u = data.usage;
        const miss = Number(u.inputTokens) || 0;
        const out = Number(u.outputTokens) || 0;
        const hit = Number(u.cacheReadTokens) || 0;
        const write = Number(u.cacheWriteTokens) || 0;

        const price = prices[model] || prices["deepseek-flash"];
        const factor = isPeak(when) ? 1.0 : 0.5;
        const cost = ((hit / 1e6) * price.hit + (miss / 1e6) * price.miss + (out / 1e6) * price.out) * factor;

        stat.cost += cost;
        if (isPeak(when)) stat.peakCost += cost; else stat.offPeakCost += cost;
        stat.inTokens += miss;
        stat.outTokens += out;
        stat.cacheRead += hit;
        stat.cacheWrite += write;
        stat.requests += 1;

        if (!stat.models[model]) stat.models[model] = { cost: 0, requests: 0, tokens: 0 };
        stat.models[model].cost += cost;
        stat.models[model].requests += 1;
        stat.models[model].tokens += miss + out + hit + write;
      }
    }
  }

  const models = Object.keys(stat.models).map((m) => ({
    model: m,
    cost: Math.round(stat.models[m].cost * 10000) / 10000,
    requests: stat.models[m].requests,
    tokens: stat.models[m].tokens,
  }));

  const result = {
    ok: files.length > 0,
    day: today,
    cost: Math.round(stat.cost * 10000) / 10000,
    peakCost: Math.round(stat.peakCost * 10000) / 10000,
    offPeakCost: Math.round(stat.offPeakCost * 10000) / 10000,
    inTokens: stat.inTokens,
    outTokens: stat.outTokens,
    cacheRead: stat.cacheRead,
    cacheWrite: stat.cacheWrite,
    tokens: stat.inTokens + stat.outTokens + stat.cacheRead + stat.cacheWrite,
    requests: stat.requests,
    files: stat.files,
    models: models,
  };
  process.stdout.write(JSON.stringify(result));
}

main();
