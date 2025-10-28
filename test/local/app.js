const express = require('express');
const app = express();

// Get environment variables with defaults
const port = process.env.PORT || 3000;
const appPool = process.env.APP_POOL || 'blue';
const releaseId = process.env.RELEASE_ID || `${appPool}-test`;

// Track chaos state
let isChaos = false;

// Version endpoint - returns pool and release info
app.get('/version', (req, res) => {
    if (isChaos) {
        res.status(500).json({ error: 'Chaos mode active' });
        return;
    }
    
    res.header('X-App-Pool', appPool);
    res.header('X-Release-Id', releaseId);
    res.json({
        pool: appPool,
        releaseId: releaseId,
        timestamp: new Date().toISOString()
    });
});

// Health check endpoint
app.get('/healthz', (req, res) => {
    if (isChaos) {
        res.status(500).json({ status: 'unhealthy', message: 'Chaos mode active' });
        return;
    }
    res.json({ status: 'healthy' });
});

// Chaos control endpoints
app.post('/chaos/start', (req, res) => {
    isChaos = true;
    console.log(`[${appPool}] Chaos mode activated`);
    res.json({ status: 'chaos started' });
});

app.post('/chaos/stop', (req, res) => {
    isChaos = false;
    console.log(`[${appPool}] Chaos mode deactivated`);
    res.json({ status: 'chaos stopped' });
});

// Start server
app.listen(port, () => {
    console.log(`[${appPool}] App listening on port ${port}`);
    console.log(`[${appPool}] Release ID: ${releaseId}`);
});