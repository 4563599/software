// AI 的静态 IP 入口；原订阅的分组、节点与规则继续保留。
// AI中转只作为内部拨号依赖隐藏，日常在 AI 分组直接选静态出口或订阅节点。
var STATIC_IP = {
  name: "静态IP出口",
  type: "http",
  server: "82.26.250.63",
  port: 7211,
  username: "请填写静态代理账号",
  password: "请填写静态代理密码"
};

// 新电脑默认使用已验证较快的中转；名称必须与订阅中的节点名称完全一致。
var PREFERRED_TRANSIT = "悦·🇹🇼台湾2 · A";

var AI_POOL = "AI中转";
var AI_CHAIN = "台湾中转→静态IP出口";
var HEALTH_URL = "http://cp.cloudflare.com/generate_204";

function main(config, profileName) {
  if (!config || typeof config !== "object") return config;
  if (String(STATIC_IP.username).indexOf("请填写") >= 0 || String(STATIC_IP.password).indexOf("请填写") >= 0) {
    throw new Error("请先填写脚本顶部 STATIC_IP 的 username 和 password");
  }
  if (!config.proxies) config.proxies = [];
  if (!config["proxy-groups"]) config["proxy-groups"] = [];
  if (!config.rules) config.rules = [];
  var retired = ["最终出口选择", "原VPN出口", "机场中转池", STATIC_IP.name];
  var i, j;
  var proxies = [];
  for (i = 0; i < config.proxies.length; i++) {
    var p = config.proxies[i];
    if (p && p.name !== STATIC_IP.name && p.name !== AI_CHAIN) proxies.push(p);
  }
  config.proxies = proxies;
  var groups = [], ai = null;
  for (i = 0; i < config["proxy-groups"].length; i++) {
    var g = config["proxy-groups"][i];
    if (!g || g.name === AI_POOL || retired.indexOf(g.name) >= 0) continue;
    if (g.proxies) {
      var members = [];
      for (j = 0; j < g.proxies.length; j++) {
        var name = g.proxies[j];
        if (name !== AI_CHAIN && name !== AI_POOL && retired.indexOf(name) < 0 && members.indexOf(name) < 0) members.push(name);
      }
      g.proxies = members;
    }
    groups.push(g);
    if (g.name === "AI") ai = g;
  }
  config["proxy-groups"] = groups;
  if (!ai) return config;
  var buckets = [[], [], [], [], [], [], [], [], []];
  for (i = 0; i < config.proxies.length; i++) {
    var item = config.proxies[i];
    if (!item || !item.name || !item.server) continue;
    if (isInfoNode(item.name)) continue;
    buckets[rankOf(item.name)].push(item.name);
  }
  var poolNames = [];
  var b, t;
  for (b = 0; b < buckets.length; b++) {
    for (t = 0; t < buckets[b].length; t++) poolNames.push(buckets[b][t]);
  }
  if (!poolNames.length) return config;

  var fastBuckets = [[], [], [], []];
  var twPlain = [];
  var twHome = [];
  for (i = 0; i < poolNames.length; i++) {
    var nodeName = poolNames[i];
    var prefer = -1;
    if (nodeName.indexOf("· A") >= 0) {
      if (nodeName.indexOf("日本家宽1") >= 0) prefer = 0;
      else if (nodeName.indexOf("香港家宽1") >= 0) prefer = 1;
      else if (nodeName.indexOf("新加坡1") >= 0 && nodeName.indexOf("专属") < 0) prefer = 2;
      else if (nodeName.indexOf("香港1") >= 0 && nodeName.indexOf("家宽") < 0) prefer = 3;
    }
    if (prefer >= 0) {
      fastBuckets[prefer].push(nodeName);
      continue;
    }
    if (nodeName.indexOf("台湾") < 0) continue;
    if (nodeName.indexOf("家宽") >= 0) twHome.push(nodeName);
    else twPlain.push(nodeName);
  }
  var fastFirst = [];
  for (b = 0; b < fastBuckets.length; b++) {
    for (t = 0; t < fastBuckets[b].length; t++) fastFirst.push(fastBuckets[b][t]);
  }
  var twNames = fastFirst.concat(twPlain).concat(twHome);
  if (!twNames.length) return config;
  var preferredIndex = twNames.indexOf(PREFERRED_TRANSIT);
  if (preferredIndex < 0) throw new Error("找不到首选中转节点，请修改 PREFERRED_TRANSIT 为当前订阅中的节点名称");
  twNames.splice(preferredIndex, 1);
  twNames.unshift(PREFERRED_TRANSIT);

  config.proxies.push({
    name: AI_CHAIN,
    type: "http",
    server: STATIC_IP.server,
    port: STATIC_IP.port,
    username: STATIC_IP.username,
    password: STATIC_IP.password,
    udp: false,
    "dialer-proxy": AI_POOL
  });
  config["proxy-groups"].push({
    name: AI_POOL,
    type: "select",
    hidden: true,
    proxies: twNames,
    url: HEALTH_URL,
    interval: 300,
    lazy: true
  });
  ai.proxies.unshift(AI_CHAIN);
  ai.url = HEALTH_URL;
  if (!ai.interval) ai.interval = 300;
  ai.lazy = true;
  ensureChinaDirect(config);
  return config;
}

function isInfoNode(name) {
  var n = String(name || "");
  return n.indexOf("剩余流量") >= 0 || n.indexOf("下次重置") >= 0 || n.indexOf("套餐到期") >= 0;
}

// 候选排序：香港九龙湾直连 > 日本东京直连 > 其余香港直连/香港 > 其余日本直连/日本 > 其余
function rankOf(name) {
  var n = String(name || "");
  if (n.indexOf("香港九龙湾直连") >= 0) return 0;
  if (n.indexOf("九龙湾") >= 0 && n.indexOf("直连") >= 0) return 0;
  if (n.indexOf("日本东京直连") >= 0) return 1;
  if (n.indexOf("东京") >= 0 && n.indexOf("直连") >= 0) return 1;
  if (n.indexOf("九龙湾") >= 0) return 2;
  if (n.indexOf("东京") >= 0) return 3;
  if (n.indexOf("香港") >= 0 && n.indexOf("直连") >= 0) return 4;
  if (n.indexOf("日本") >= 0 && n.indexOf("直连") >= 0) return 5;
  if (n.indexOf("香港") >= 0) return 6;
  if (n.indexOf("日本") >= 0) return 7;
  return 8;
}

function ensureChinaDirect(config) {
  var i;
  for (i = 0; i < config.rules.length; i++) {
    var rule = String(config.rules[i]);
    if (rule === "GEOSITE,cn,DIRECT" || rule === "GEOSITE,CN,DIRECT") return;
  }
  for (i = 0; i < config.rules.length; i++) {
    if (String(config.rules[i]).indexOf("MATCH,") === 0) {
      config.rules.splice(i, 0, "GEOSITE,cn,DIRECT");
      return;
    }
  }
  config.rules.push("GEOSITE,cn,DIRECT");
}
