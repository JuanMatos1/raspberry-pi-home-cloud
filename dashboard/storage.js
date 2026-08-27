const fs = require("fs/promises");

async function getDiskUsage(mountPath) {
  try {
    const stats = await fs.statfs(mountPath);

    const totalBytes = stats.blocks * stats.bsize;
    const availableBytes = stats.bavail * stats.bsize;
    const freeBytes = stats.bfree * stats.bsize;
    const usedBytes = totalBytes - freeBytes;

    return {
      available: true,
      totalGB: Number((totalBytes / 1024 ** 3).toFixed(1)),
      usedGB: Number((usedBytes / 1024 ** 3).toFixed(1)),
      freeGB: Number((availableBytes / 1024 ** 3).toFixed(1)),
      usagePercent: Number(
        ((usedBytes / (usedBytes + availableBytes)) * 100).toFixed(1)
      )
    };
  } catch {
    return {
      available: false
    };
  }
}

async function getStorageMetrics() {
  const [nvme, backup] = await Promise.all([
    getDiskUsage("/metrics/nvme"),
    getDiskUsage("/metrics/backup")
  ]);

  return {
    nvme,
    backup
  };
}

module.exports = {
  getStorageMetrics
};
