#!/bin/bash
# 一键安装分布式压测 Master 脚本

set -e

echo "========== 分布式压力测试 Master 安装 =========="

MASTER_DIR="/opt/stress-master"
MASTER_JS="$MASTER_DIR/master-server.js"
PACKAGE_JSON="$MASTER_DIR/package.json"

# 1. 安装 Node.js（如未安装）
if ! which node >/dev/null 2>&1; then
  echo "检测到未安装 Node.js，开始安装..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

# 2. 创建程序目录
mkdir -p $MASTER_DIR
cd $MASTER_DIR

# 3. 创建主服务器文件
cat > $MASTER_JS <<'EOF'
const WebSocket = require('ws');
const http = require('http');
const PORT = 8080;
const AUTH_TOKEN = '!Ux4E@)shf*9rDKh:,j!0L5}^!6,*Y'; // !!!请修改!!!

const workers = new Map();
const clients = new Map();

const server = http.createServer();
const wss = new WebSocket.Server({ server });

wss.on('connection', (ws, req) => {
    const clientId = Math.random().toString(36).substring(7);
    const clientIP = req.socket.remoteAddress;
    ws.on('message', (message) => {
        try {
            const data = JSON.parse(message);
            handleMessage(ws, data, clientId, clientIP);
        } catch (error) {
            ws.send(JSON.stringify({
                type: 'error',
                message: '无效的消息格式'
            }));
        }
    });
    ws.on('close', () => {
        workers.delete(clientId);
        clients.delete(clientId);
        broadcastWorkerList();
    });
});

function handleMessage(ws, data, clientId, clientIP) {
    switch (data.type) {
        case 'auth':
            if (data.token === AUTH_TOKEN) {
                clients.set(clientId, { ws, type: 'control', ip: clientIP });
                ws.send(JSON.stringify({ type: 'auth_success', message: '授权成功' }));
            } else {
                ws.send(JSON.stringify({ type: 'auth_failed', message: '授权失败：Token无效' }));
                ws.close();
            }
            break;
        case 'register_worker':
            workers.set(clientId, { id: clientId, ip: clientIP, status: 'idle', ws: ws });
            ws.send(JSON.stringify({ type: 'worker_registered', workerId: clientId }));
            broadcastWorkerList();
            break;
        case 'get_workers':
            const workerList = Array.from(workers.values()).map(w => ({
                id: w.id, ip: w.ip, status: w.status
            }));
            ws.send(JSON.stringify({ type: 'workers_list', workers: workerList }));
            break;
        case 'start_test':
            workers.forEach(worker => {
                worker.status = 'running';
                worker.ws.send(JSON.stringify({ type: 'start_attack', config: data }));
            });
            broadcastWorkerList();
            break;
        case 'stop_test':
            workers.forEach(worker => {
                worker.status = 'idle';
                worker.ws.send(JSON.stringify({ type: 'stop_attack' }));
            });
            broadcastWorkerList();
            break;
        case 'stats_update':
            clients.forEach(client => {
                if (client.type === 'control') {
                    client.ws.send(JSON.stringify({
                        type: 'stats_update',
                        stats: data.stats,
                        workerId: clientId
                    }));
                }
            });
            break;
    }
}

function broadcastWorkerList() {
    const workerList = Array.from(workers.values()).map(w => ({
        id: w.id, ip: w.ip, status: w.status
    }));
    clients.forEach(client => {
        if (client.type === 'control') {
            client.ws.send(JSON.stringify({ type: 'workers_list', workers: workerList }));
        }
    });
}

server.listen(PORT, '0.0.0.0', () => {
    console.log('=================================');
    console.log('Master 服务器已启动');
    console.log('WebSocket 端口:', PORT);
    console.log('授权 Token:', AUTH_TOKEN);
    console.log('=================================');
});
EOF

# 4. 生成package.json
cat > $PACKAGE_JSON << EOF
{
  "name": "stress-master",
  "version": "1.0.0",
  "main": "master-server.js",
  "dependencies": {
    "ws": "^8.18.0"
  }
}
EOF

# 5. 安装依赖
npm install

# 6. 启动（推荐用 PM2 或 nohup）
npm install -g pm2 || true
pm2 start $MASTER_JS --name stress-master || nohup node $MASTER_JS > master.log 2>&1 &
echo "🚀 Master服务启动成功！"
echo "Web端配置 Master节点地址： ws://$(hostname -I | awk '{print $1}'):8080"
echo "如需后台守护进程运行，建议: npm install -g pm2 && pm2 start $MASTER_JS --name stress-master"
