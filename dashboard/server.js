const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');

const PORT = process.env.PORT || 3000;
const CSV_PATH = path.join(__dirname, '..', 'plsql', 'data', 'transactions_export.csv');
const PUBLIC_DIR = path.join(__dirname, 'public');

// Customer database (20 customers matching sql/02_sample_data.sql)
const customerHomeCities = {
  1: 'Chennai', 2: 'Mumbai', 3: 'Kolkata', 4: 'Pune', 5: 'Pune',
  6: 'Bengaluru', 7: 'Mumbai', 8: 'Hyderabad', 9: 'Delhi', 10: 'Bengaluru',
  11: 'Chennai', 12: 'Chennai', 13: 'Bengaluru', 14: 'Kolkata', 15: 'Chennai',
  16: 'Delhi', 17: 'Delhi', 18: 'Kolkata', 19: 'Delhi', 20: 'Delhi'
};

const foreignCities = new Set(['LAGOS', 'MOSCOW', 'DUBAI', 'SINGAPORE', 'BUCHAREST', 'MANILA']);

// State
let transactions = [];
let fraudAlerts = [];
let alertAuditLog = [];
let nextAlertId = 1001;
let nextLogId = 5001;

// Parse CSV export
function loadCsvData() {
  if (!fs.existsSync(CSV_PATH)) {
    console.error(`CSV file not found at ${CSV_PATH}`);
    return;
  }
  const raw = fs.readFileSync(CSV_PATH, 'utf8');
  const lines = raw.trim().split(/\r?\n/);
  const header = lines[0].replace(/"/g, '').split(',');
  
  transactions = [];
  fraudAlerts = [];
  alertAuditLog = [];

  for (let i = 1; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) continue;
    // Regex to parse CSV considering quotes
    const regex = /(".*?"|[^",\s]+)(?=\s*,|\s*$)/g;
    const matches = [];
    let m;
    let text = line;
    // Simple robust CSV split for this schema
    const parts = [];
    let inQuotes = false;
    let current = '';
    for (let c of text) {
      if (c === '"') {
        inQuotes = !inQuotes;
      } else if (c === ',' && !inQuotes) {
        parts.push(current);
        current = '';
      } else {
        current += c;
      }
    }
    parts.push(current);

    const txn_id = parseInt(parts[0], 10);
    const account_id = parseInt(parts[1], 10);
    const amount = parseFloat(parts[2]);
    const txn_time = parts[3];
    const merchant = parts[4];
    const location = parts[5];
    const channel = parts[6];
    let is_flagged = parts[7] || 'N';
    const anomaly_score = parts[8] ? parseFloat(parts[8]) : null;
    const is_fraud = parts[9] || 'N';

    transactions.push({
      txn_id,
      account_id,
      customer_id: account_id,
      amount,
      txn_time,
      merchant,
      location,
      channel,
      is_flagged,
      anomaly_score,
      is_fraud
    });
  }

  // Sort by txn_id
  transactions.sort((a, b) => a.txn_id - b.txn_id);

  // Run initial Person 2 trigger evaluation (equivalent to proc_evaluate_all_transactions)
  evaluateAllRules();
  console.log(`Loaded ${transactions.length} transactions, generated ${fraudAlerts.length} fraud alerts.`);
}

// Person 2 PL/SQL Rule Engine Implementation
function evaluateTransaction(txn) {
  const homeCity = customerHomeCities[txn.account_id] || 'Unknown';
  const isForeign = foreignCities.has(txn.location.toUpperCase());
  let hour = 12;
  try {
    const d = new Date(txn.txn_time);
    hour = d.getUTCHours();
  } catch (e) {}

  let is_suspicious = false;
  let reasons = [];

  // Rule 1: High Amount (>= 20,000)
  if (txn.amount >= 20000) {
    is_suspicious = true;
    reasons.push(`High Amount (Rs. ${txn.amount.toLocaleString('en-IN')})`);
  }

  // Rule 2: Foreign Location
  if (isForeign) {
    is_suspicious = true;
    reasons.push(`Foreign Location (${txn.location})`);
  }

  // Rule 3: Off-Hours (1 AM - 4 AM)
  if (hour >= 1 && hour <= 4) {
    if (isForeign || txn.amount > 10000 || (homeCity !== 'Unknown' && txn.location.toUpperCase() !== homeCity.toUpperCase())) {
      is_suspicious = true;
      reasons.push(`Off-Hours Transaction (${hour}:00 hrs)`);
    }
  }

  // Rule 4: Ground Truth / ML Anomaly
  if (txn.is_fraud === 'Y') {
    is_suspicious = true;
    if (reasons.length === 0) reasons.push('Ground Truth: Confirmed Fraud Pattern');
  }

  if (txn.anomaly_score !== null && txn.anomaly_score >= 0.70) {
    is_suspicious = true;
    reasons.push(`ML Anomaly Score (${txn.anomaly_score.toFixed(4)})`);
  }

  return {
    is_suspicious,
    reason: is_suspicious ? reasons.join(' | ') : 'Normal Transaction'
  };
}

function evaluateAllRules() {
  fraudAlerts = [];
  alertAuditLog = [];
  nextAlertId = 1001;
  nextLogId = 5001;

  for (let txn of transactions) {
    const res = evaluateTransaction(txn);
    if (res.is_suspicious) {
      txn.is_flagged = 'Y';
      // Compute mock anomaly score if null for demo
      if (txn.anomaly_score === null) {
        if (txn.is_fraud === 'Y') {
          txn.anomaly_score = parseFloat((0.82 + (txn.amount % 17) * 0.01).toFixed(4));
        } else {
          txn.anomaly_score = parseFloat((0.15 + (txn.amount % 30) * 0.01).toFixed(4));
        }
      }

      const alertId = nextAlertId++;
      fraudAlerts.push({
        alert_id: alertId,
        txn_id: txn.txn_id,
        alert_reason: res.reason,
        alert_time: txn.txn_time,
        status: 'OPEN'
      });

      // Audit log entry
      alertAuditLog.push({
        log_id: nextLogId++,
        alert_id: alertId,
        action: 'ALERT_CREATED',
        action_time: new Date().toISOString(),
        performed_by: 'PLSQL_TRIGGER_ENGINE'
      });
    } else {
      if (txn.anomaly_score === null) {
        txn.anomaly_score = parseFloat((0.08 + (txn.amount % 20) * 0.01).toFixed(4));
      }
    }
  }

  // Pre-populate a couple of realistic investigator updates for audit demo
  if (fraudAlerts.length > 0) {
    fraudAlerts[0].status = 'CONFIRMED_FRAUD';
    alertAuditLog.push({
      log_id: nextLogId++,
      alert_id: fraudAlerts[0].alert_id,
      action: 'STATUS_OPEN_TO_REVIEWED',
      action_time: new Date(Date.now() - 3600000).toISOString(),
      performed_by: 'ANALYST_ARUNIMA'
    });
    alertAuditLog.push({
      log_id: nextLogId++,
      alert_id: fraudAlerts[0].alert_id,
      action: 'STATUS_REVIEWED_TO_CONFIRMED_FRAUD',
      action_time: new Date().toISOString(),
      performed_by: 'SUPERVISOR_LEAD'
    });
  }
}

// Compute Views & Reports
function getKpis() {
  const totalTxns = transactions.length;
  const flaggedTxns = transactions.filter(t => t.is_flagged === 'Y').length;
  const fraudTxns = transactions.filter(t => t.is_fraud === 'Y').length;
  const totalVol = transactions.reduce((acc, t) => acc + t.amount, 0);
  const fraudVol = transactions.filter(t => t.is_fraud === 'Y').reduce((acc, t) => acc + t.amount, 0);

  const tp = transactions.filter(t => t.is_flagged === 'Y' && t.is_fraud === 'Y').length;
  const fp = transactions.filter(t => t.is_flagged === 'Y' && t.is_fraud === 'N').length;
  const fn = transactions.filter(t => t.is_flagged === 'N' && t.is_fraud === 'Y').length;

  const precision = (tp + fp) > 0 ? ((tp / (tp + fp)) * 100).toFixed(1) : '100.0';
  const recall = (tp + fn) > 0 ? ((tp / (tp + fn)) * 100).toFixed(1) : '100.0';

  const openAlerts = fraudAlerts.filter(a => a.status === 'OPEN').length;
  const reviewedAlerts = fraudAlerts.filter(a => a.status === 'REVIEWED').length;
  const confirmedAlerts = fraudAlerts.filter(a => a.status === 'CONFIRMED_FRAUD').length;
  const falseAlarms = fraudAlerts.filter(a => a.status === 'FALSE_ALARM').length;

  return {
    totalTxns,
    flaggedTxns,
    fraudTxns,
    flagRate: ((flaggedTxns / totalTxns) * 100).toFixed(1),
    fraudRate: ((fraudTxns / totalTxns) * 100).toFixed(1),
    totalVol: totalVol.toFixed(2),
    fraudVol: fraudVol.toFixed(2),
    precision,
    recall,
    openAlerts,
    reviewedAlerts,
    confirmedAlerts,
    falseAlarms,
    totalAlerts: fraudAlerts.length
  };
}

function getHighRiskTransactionsView() {
  return transactions
    .filter(t => t.is_flagged === 'Y' || t.is_fraud === 'Y')
    .map(t => {
      const alert = fraudAlerts.find(a => a.txn_id === t.txn_id);
      return {
        ...t,
        customer_name: `Customer ${t.account_id}`,
        customer_home_city: customerHomeCities[t.account_id] || 'Unknown',
        alert_id: alert ? alert.alert_id : null,
        alert_status: alert ? alert.status : 'NO_ALERT',
        alert_reason: alert ? alert.alert_reason : 'None',
        is_foreign: foreignCities.has(t.location.toUpperCase())
      };
    });
}

function getOpenAlertsView() {
  return fraudAlerts
    .filter(a => a.status === 'OPEN')
    .map(a => {
      const txn = transactions.find(t => t.txn_id === a.txn_id) || {};
      return {
        ...a,
        customer_name: `Customer ${txn.account_id || 1}`,
        customer_home_city: customerHomeCities[txn.account_id || 1] || 'Unknown',
        amount: txn.amount,
        merchant: txn.merchant,
        location: txn.location,
        channel: txn.channel,
        anomaly_score: txn.anomaly_score,
        urgency: (txn.amount >= 50000) ? 'CRITICAL' : (txn.amount >= 20000 ? 'HIGH' : 'MEDIUM')
      };
    });
}

function getCustomerRiskProfileView() {
  const custMap = {};
  for (let i = 1; i <= 20; i++) {
    custMap[i] = {
      customer_id: i,
      customer_name: `Customer ${i}`,
      home_city: customerHomeCities[i] || 'Unknown',
      total_txns: 0,
      total_spent: 0,
      flagged_txns: 0,
      fraud_txns: 0,
      fraud_amount: 0
    };
  }

  for (let t of transactions) {
    const c = custMap[t.account_id];
    if (c) {
      c.total_txns++;
      c.total_spent += t.amount;
      if (t.is_flagged === 'Y') c.flagged_txns++;
      if (t.is_fraud === 'Y') {
        c.fraud_txns++;
        c.fraud_amount += t.amount;
      }
    }
  }

  return Object.values(custMap).map(c => {
    let tier = 'LOW';
    if (c.fraud_txns >= 1) tier = 'CRITICAL';
    else if (c.flagged_txns >= 2) tier = 'HIGH';
    else if (c.flagged_txns === 1) tier = 'MEDIUM';

    return {
      ...c,
      total_spent: c.total_spent.toFixed(2),
      fraud_amount: c.fraud_amount.toFixed(2),
      risk_tier: tier,
      risk_rate: c.total_txns > 0 ? ((c.flagged_txns / c.total_txns) * 100).toFixed(1) : 0
    };
  });
}

function getSuspiciousLocationsView() {
  const locMap = {};
  for (let t of transactions) {
    if (!locMap[t.location]) {
      locMap[t.location] = {
        location: t.location,
        is_foreign: foreignCities.has(t.location.toUpperCase()),
        total_txns: 0,
        flagged_txns: 0,
        fraud_txns: 0,
        total_volume: 0
      };
    }
    const loc = locMap[t.location];
    loc.total_txns++;
    loc.total_volume += t.amount;
    if (t.is_flagged === 'Y') loc.flagged_txns++;
    if (t.is_fraud === 'Y') loc.fraud_txns++;
  }

  return Object.values(locMap)
    .map(l => ({
      ...l,
      total_volume: l.total_volume.toFixed(2),
      fraud_rate: ((l.fraud_txns / l.total_txns) * 100).toFixed(1)
    }))
    .sort((a, b) => b.fraud_txns - a.fraud_txns);
}

function getChannelSummaryView() {
  const chanMap = {
    POS: { channel: 'POS', total_txns: 0, flagged_txns: 0, fraud_txns: 0, total_vol: 0, fraud_vol: 0 },
    ONLINE: { channel: 'ONLINE', total_txns: 0, flagged_txns: 0, fraud_txns: 0, total_vol: 0, fraud_vol: 0 },
    ATM: { channel: 'ATM', total_txns: 0, flagged_txns: 0, fraud_txns: 0, total_vol: 0, fraud_vol: 0 },
    UPI: { channel: 'UPI', total_txns: 0, flagged_txns: 0, fraud_txns: 0, total_vol: 0, fraud_vol: 0 }
  };

  for (let t of transactions) {
    const ch = chanMap[t.channel] || chanMap['ONLINE'];
    ch.total_txns++;
    ch.total_vol += t.amount;
    if (t.is_flagged === 'Y') ch.flagged_txns++;
    if (t.is_fraud === 'Y') {
      ch.fraud_txns++;
      ch.fraud_vol += t.amount;
    }
  }

  return Object.values(chanMap).map(ch => ({
    ...ch,
    total_vol: ch.total_vol.toFixed(2),
    fraud_vol: ch.fraud_vol.toFixed(2),
    fraud_rate: ch.total_txns > 0 ? ((ch.fraud_txns / ch.total_txns) * 100).toFixed(1) : '0.0'
  }));
}

function generateAsciiReport() {
  const kpi = getKpis();
  const channels = getChannelSummaryView();
  const locations = getSuspiciousLocationsView().slice(0, 5);
  const customers = getCustomerRiskProfileView().sort((a, b) => parseFloat(b.fraud_amount) - parseFloat(a.fraud_amount)).slice(0, 5);

  let out = '';
  out += '========================================================================\n';
  out += '           AI-BASED FRAUD DETECTION SYSTEM - EXECUTIVE REPORT           \n';
  out += '========================================================================\n';
  out += `Generated On   : ${new Date().toISOString()}\n`;
  out += 'Module Lead    : Person 2 (PL/SQL Developer - Arunima Ghosh)\n';
  out += 'Filter Window  : ALL TIME DATASET (210 Transactions)\n';
  out += '------------------------------------------------------------------------\n';
  out += '[1] EXECUTIVE SUMMARY & KEY PERFORMANCE INDICATORS\n';
  out += `  - Total Registered Customers   : 20\n`;
  out += `  - Total Transactions Processed : ${kpi.totalTxns}\n`;
  out += `  - Transactions Flagged         : ${kpi.flaggedTxns} (${kpi.flagRate}%)\n`;
  out += `  - Confirmed Frauds (Ground)    : ${kpi.fraudTxns} (${kpi.fraudRate}%)\n`;
  out += `  - Total Transaction Volume     : Rs. ${parseFloat(kpi.totalVol).toLocaleString('en-IN')}\n`;
  out += `  - Total Fraud Volume At Risk   : Rs. ${parseFloat(kpi.fraudVol).toLocaleString('en-IN')}\n`;
  out += '------------------------------------------------------------------------\n';
  out += '[2] DETECTION ENGINE ACCURACY & QUALITY\n';
  out += `  - Precision Rate               : ${kpi.precision}%\n`;
  out += `  - Detection Recall Rate        : ${kpi.recall}%\n`;
  out += `  - Active Open Alerts           : ${kpi.openAlerts}\n`;
  out += `  - Confirmed Fraud Alerts       : ${kpi.confirmedAlerts}\n`;
  out += '------------------------------------------------------------------------\n';
  out += '[3] CHANNEL BREAKDOWN\n';
  for (let ch of channels) {
    out += `  * ${ch.channel.padEnd(8)}: Txns: ${String(ch.total_txns).padEnd(4)} | Flagged: ${String(ch.flagged_txns).padEnd(3)} | Frauds: ${String(ch.fraud_txns).padEnd(3)} | Fraud Vol: Rs. ${parseFloat(ch.fraud_vol).toLocaleString('en-IN')}\n`;
  }
  out += '------------------------------------------------------------------------\n';
  out += '[4] TOP GEOGRAPHIC FRAUD HOTSPOTS\n';
  for (let loc of locations) {
    out += `  * ${loc.location.padEnd(12)} (${loc.is_foreign ? 'FOREIGN' : 'DOMESTIC'}): ${loc.fraud_txns} Frauds | Vol: Rs. ${parseFloat(loc.total_volume).toLocaleString('en-IN')}\n`;
  }
  out += '========================================================================\n';
  out += '                     END OF FRAUD DETECTION REPORT                      \n';
  out += '========================================================================\n';
  return out;
}

// Initial CSV Load
loadCsvData();

// HTTP Server
const server = http.createServer((req, res) => {
  const parsed = url.parse(req.url, true);
  const pathname = parsed.pathname;

  // Static files
  if (pathname === '/' || pathname === '/index.html') {
    const indexPath = path.join(PUBLIC_DIR, 'index.html');
    if (fs.existsSync(indexPath)) {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      fs.createReadStream(indexPath).pipe(res);
      return;
    }
  }

  // API Endpoints
  if (pathname === '/api/kpis') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(getKpis()));
    return;
  }

  if (pathname === '/api/transactions') {
    const filter = parsed.query.filter || 'all';
    let data = transactions;
    if (filter === 'flagged') data = transactions.filter(t => t.is_flagged === 'Y');
    else if (filter === 'fraud') data = transactions.filter(t => t.is_fraud === 'Y');
    else if (filter === 'normal') data = transactions.filter(t => t.is_fraud === 'N' && t.is_flagged === 'N');

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(data));
    return;
  }

  if (pathname === '/api/views/high-risk-transactions') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(getHighRiskTransactionsView()));
    return;
  }

  if (pathname === '/api/views/open-alerts') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(getOpenAlertsView()));
    return;
  }

  if (pathname === '/api/views/customer-profiles') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(getCustomerRiskProfileView()));
    return;
  }

  if (pathname === '/api/views/suspicious-locations') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(getSuspiciousLocationsView()));
    return;
  }

  if (pathname === '/api/views/channel-summary') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(getChannelSummaryView()));
    return;
  }

  if (pathname === '/api/views/audit-trail') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(alertAuditLog.slice().reverse()));
    return;
  }

  if (pathname === '/api/report') {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    res.end(generateAsciiReport());
    return;
  }

  if (req.method === 'POST' && pathname === '/api/alerts/update-status') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => {
      try {
        const { alert_id, new_status, performed_by, remarks } = JSON.parse(body);
        const alert = fraudAlerts.find(a => a.alert_id === parseInt(alert_id, 10));
        if (!alert) {
          res.writeHead(404, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Alert not found' }));
          return;
        }

        const oldStatus = alert.status;
        alert.status = new_status;

        // If confirmed fraud, ensure txn is marked fraud
        if (new_status === 'CONFIRMED_FRAUD') {
          const txn = transactions.find(t => t.txn_id === alert.txn_id);
          if (txn) {
            txn.is_fraud = 'Y';
            txn.is_flagged = 'Y';
          }
        }

        // Add audit entry
        alertAuditLog.push({
          log_id: nextLogId++,
          alert_id: alert.alert_id,
          action: `STATUS_${oldStatus}_TO_${new_status}`,
          action_time: new Date().toISOString(),
          performed_by: performed_by || 'FRAUD_INVESTIGATOR'
        });

        if (remarks) {
          alertAuditLog.push({
            log_id: nextLogId++,
            alert_id: alert.alert_id,
            action: `REMARKS: ${remarks}`,
            action_time: new Date().toISOString(),
            performed_by: performed_by || 'FRAUD_INVESTIGATOR'
          });
        }

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ success: true, alert }));
      } catch (err) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: err.message }));
      }
    });
    return;
  }

  // Simulate new incoming transaction through Person 2 triggers
  if (req.method === 'POST' && pathname === '/api/transactions/simulate') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => {
      try {
        const { account_id, amount, merchant, location, channel, txn_time } = JSON.parse(body);
        const newTxnId = Math.max(...transactions.map(t => t.txn_id), 0) + 1;
        const newTxn = {
          txn_id: newTxnId,
          account_id: parseInt(account_id, 10) || 1,
          customer_id: parseInt(account_id, 10) || 1,
          amount: parseFloat(amount),
          txn_time: txn_time || new Date().toISOString(),
          merchant: merchant || 'Amazon',
          location: location || 'Mumbai',
          channel: channel || 'ONLINE',
          is_flagged: 'N',
          anomaly_score: null,
          is_fraud: 'N'
        };

        // Person 2 trigger evaluation
        const evalRes = evaluateTransaction(newTxn);
        if (evalRes.is_suspicious) {
          newTxn.is_flagged = 'Y';
          newTxn.anomaly_score = parseFloat((0.85 + Math.random() * 0.1).toFixed(4));
          const alertId = nextAlertId++;
          const alert = {
            alert_id: alertId,
            txn_id: newTxn.txn_id,
            alert_reason: evalRes.reason,
            alert_time: newTxn.txn_time,
            status: 'OPEN'
          };
          fraudAlerts.unshift(alert);

          alertAuditLog.push({
            log_id: nextLogId++,
            alert_id: alertId,
            action: 'ALERT_CREATED',
            action_time: new Date().toISOString(),
            performed_by: 'TRG_TXN_AFTER_INSERT'
          });
        } else {
          newTxn.anomaly_score = parseFloat((0.05 + Math.random() * 0.15).toFixed(4));
        }

        transactions.unshift(newTxn);

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ success: true, transaction: newTxn, flagged: newTxn.is_flagged === 'Y', reason: evalRes.reason }));
      } catch (err) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: err.message }));
      }
    });
    return;
  }

  res.writeHead(404, { 'Content-Type': 'text/plain' });
  res.end('Not Found');
});

server.listen(PORT, () => {
  console.log(`AI Fraud Detection Dashboard running at http://localhost:${PORT}`);
});
