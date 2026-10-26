// Import Express to create the web server and API routes.
const express = require("express");

// Import Node.js utilities for reading operating-system information,
// such as CPU details, memory usage, architecture, and uptime.
const os = require("os");

// Import path utilities to safely construct filesystem paths.
const path = require("path");

// Import the promise-based filesystem API.
// This is used to read the Raspberry Pi temperature sensor.
const fs = require("fs/promises");

// Import the custom function that collects SSD/storage information.
const { getStorageMetrics } = require("./storage");

// Create the Express application.
const app = express();

// Define the internal port used by the dashboard container.
const PORT = 3000;

/*
 * Serve the frontend files from the "public" directory.
 *
 * For example:
 * public/index.html
 *
 * When a visitor opens the dashboard, Express automatically sends
 * the files located in this directory.
 */
app.use(express.static(path.join(__dirname, "public")));
app.use(express.json({ limit: "4kb" }));

/*
 * Capture the current CPU-time counters for every processor core.
 *
 * Node.js reports how much time each core has spent in different states:
 * user, nice, system, idle, and irq.
 *
 * These snapshots are compared later to estimate current CPU usage.
 */
function getCpuSnapshot() {
  return os.cpus().map((cpu) => {
    // Add all CPU state times together to obtain the total CPU time.
    const total = Object.values(cpu.times).reduce(
      (sum, value) => sum + value,
      0
    );

    // Return only the values needed for the CPU usage calculation.
    return {
      idle: cpu.times.idle,
      total
    };
  });
}

/*
 * Pause execution for a specified number of milliseconds.
 *
 * This helper is used to place a small delay between two CPU snapshots.
 */
function wait(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

/*
 * Estimate the Raspberry Pi's current CPU usage percentage.
 *
 * The function:
 * 1. Takes an initial CPU snapshot.
 * 2. Waits 500 milliseconds.
 * 3. Takes another snapshot.
 * 4. Calculates how much of that time the CPU was busy.
 */
async function getCpuUsage() {
  const start = getCpuSnapshot();

  // Wait half a second before collecting the second measurement.
  await wait(500);

  const end = getCpuSnapshot();

  // Store the combined differences from all CPU cores.
  let idleDifference = 0;
  let totalDifference = 0;

  // Compare the starting and ending values for every CPU core.
  for (let index = 0; index < start.length; index += 1) {
    idleDifference += end[index].idle - start[index].idle;
    totalDifference += end[index].total - start[index].total;
  }

  // Prevent division by zero if the CPU counters did not change.
  if (totalDifference === 0) {
    return 0;
  }

  /*
   * Calculate the busy percentage:
   *
   * CPU usage = 1 - (idle time / total time)
   *
   * Multiply by 100 to convert it to a percentage and round it
   * to one decimal place.
   */
  return Number(
    ((1 - idleDifference / totalDifference) * 100).toFixed(1)
  );
}

/*
 * Read the Raspberry Pi's CPU temperature.
 *
 * Linux exposes the temperature through a virtual system file.
 * The file reports temperature in thousandths of a degree Celsius,
 * so the value must be divided by 1,000.
 */
async function getTemperature() {
  try {
    const rawTemperature = await fs.readFile(
      "/sys/class/thermal/thermal_zone0/temp",
      "utf8"
    );

    // Convert the raw value to Celsius and round it to one decimal place.
    return Number((Number(rawTemperature.trim()) / 1000).toFixed(1));
  } catch {
    /*
     * Return null if the temperature file is unavailable.
     * This allows the dashboard to continue working on systems
     * that do not expose this sensor.
     */
    return null;
  }
}

/*
 * GET /api/status
 *
 * Collect the Raspberry Pi's current system metrics and return them
 * to the dashboard as JSON.
 */
app.get("/api/status", async (req, res) => {
  try {
    // Read the total and currently available system memory in bytes.
    const totalMemory = os.totalmem();
    const freeMemory = os.freemem();

    // Calculate how much memory is currently being used.
    const usedMemory = totalMemory - freeMemory;

    /*
     * Collect CPU, temperature, and storage metrics concurrently.
     * Promise.all makes the requests run together instead of waiting
     * for each operation to finish one at a time.
     */
    const [cpuUsage, temperature, storage] = await Promise.all([
      getCpuUsage(),
      getTemperature(),
      getStorageMetrics()
    ]);

    // Send all collected metrics to the frontend as a JSON response.
    res.json({
      // Basic server identity and operating status.
      server: "JuanCloud",
      status: "online",

      // Operating-system and hardware information.
      platform: os.platform(),
      architecture: os.arch(),
      cpuCores: os.cpus().length,

      // Current CPU activity.
      cpuUsagePercent: cpuUsage,

      /*
       * The one-minute load average represents the average amount
       * of work waiting for or using the CPU.
       */
      loadAverage: Number(os.loadavg()[0].toFixed(2)),

      // Memory values converted from bytes to gigabytes.
      memory: {
        totalGB: Number((totalMemory / 1024 ** 3).toFixed(2)),
        usedGB: Number((usedMemory / 1024 ** 3).toFixed(2)),
        usagePercent: Number(
          ((usedMemory / totalMemory) * 100).toFixed(1)
        )
      },

      // Number of seconds since the Raspberry Pi was last started.
      uptimeSeconds: Math.floor(os.uptime()),

      // CPU temperature in degrees Celsius.
      temperatureCelsius: temperature,

      // Storage information returned by storage.js.
      storage,

      // UTC date and time when these metrics were collected.
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    /*
     * Return HTTP status 500 if an unexpected error prevents
     * the server from collecting the system metrics.
     */
    res.status(500).json({
      status: "error",
      message: "Unable to collect server metrics"
    });
  }
});

/*
 * GET /health
 *
 * A lightweight health-check endpoint used to verify that the
 * Express application is running and responding to requests.
 */
app.get("/health", (req, res) => {
  res.json({
    status: "healthy",
    timestamp: new Date().toISOString()
  });
});

/*
 * Start the Express server.
 *
 * Listening on 0.0.0.0 allows the application to accept connections
 * through the container's network interfaces. Docker still publishes
 * it only through 127.0.0.1:3000 on the Raspberry Pi, as configured
 * in compose.yaml.
 */
/* BEGIN JUANCLOUD AIOPS ROUTES - local dashboard proxy, no credentials */
app.get('/api/health-report', async (_req, res) => {
  try {
    const contents = await fs.readFile('/metrics/health/status.json', 'utf8');
    res.set('Cache-Control', 'no-store');
    res.type('json').send(contents);
  } catch {
    res.status(503).json({error:'Monitoring report unavailable. Check systemd timer.'});
  }
});
app.post('/api/ask-ai', async (req, res) => {
  const question = req.body?.question;
  if (typeof question !== 'string' || !question.trim() || question.length > 1000) {
    return res.status(400).json({error:'Question must contain 1–1000 characters.'});
  }
  try {
    const response = await fetch('http://host.docker.internal:3001/ask-ai', {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body:JSON.stringify({question}),
      signal:AbortSignal.timeout(150000)
    });
    const result = await response.text();
    res.status(response.status).type('json').send(result);
  } catch {
    res.status(503).json({error:'AI assistant unavailable or timed out.'});
  }
});
/* END JUANCLOUD AIOPS ROUTES */

app.listen(PORT, "0.0.0.0", () => {
  console.log(`JuanCloud Dashboard running on port ${PORT}`);
});
