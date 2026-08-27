const express = require("express");
const os = require("os");
const path = require("path");
const fs = require("fs/promises");
const { getStorageMetrics } = require("./storage");

const app = express();
const PORT = 3000;

app.use(express.static(path.join(__dirname, "public")));

function getCpuSnapshot() {
  return os.cpus().map((cpu) => {
    const total = Object.values(cpu.times).reduce(
      (sum, value) => sum + value,
      0
    );

    return {
      idle: cpu.times.idle,
      total
    };
  });
}

function wait(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function getCpuUsage() {
  const start = getCpuSnapshot();
  await wait(500);
  const end = getCpuSnapshot();

  let idleDifference = 0;
  let totalDifference = 0;

  for (let index = 0; index < start.length; index += 1) {
    idleDifference += end[index].idle - start[index].idle;
    totalDifference += end[index].total - start[index].total;
  }

  if (totalDifference === 0) {
    return 0;
  }

  return Number(
    ((1 - idleDifference / totalDifference) * 100).toFixed(1)
  );
}

async function getTemperature() {
  try {
    const rawTemperature = await fs.readFile(
      "/sys/class/thermal/thermal_zone0/temp",
      "utf8"
    );

    return Number((Number(rawTemperature.trim()) / 1000).toFixed(1));
  } catch {
    return null;
  }
}

app.get("/api/status", async (req, res) => {
  try {
    const totalMemory = os.totalmem();
    const freeMemory = os.freemem();
    const usedMemory = totalMemory - freeMemory;

    const [cpuUsage, temperature, storage] = await Promise.all([
      getCpuUsage(),
      getTemperature(),
      getStorageMetrics()
    ]);

    res.json({
      server: "JuanCloud",
      status: "online",
      platform: os.platform(),
      architecture: os.arch(),
      cpuCores: os.cpus().length,
      cpuUsagePercent: cpuUsage,
      loadAverage: Number(os.loadavg()[0].toFixed(2)),
      memory: {
        totalGB: Number((totalMemory / 1024 ** 3).toFixed(2)),
        usedGB: Number((usedMemory / 1024 ** 3).toFixed(2)),
        usagePercent: Number(
          ((usedMemory / totalMemory) * 100).toFixed(1)
        )
      },
      uptimeSeconds: Math.floor(os.uptime()),
      temperatureCelsius: temperature,
      storage,
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    res.status(500).json({
      status: "error",
      message: "Unable to collect server metrics"
    });
  }
});

app.get("/health", (req, res) => {
  res.json({
    status: "healthy",
    timestamp: new Date().toISOString()
  });
});

app.listen(PORT, "0.0.0.0", () => {
  console.log(`JuanCloud Dashboard running on port ${PORT}`);
});
