// Import Node.js's promise-based filesystem API.
// It provides the statfs() function used to read filesystem statistics.
const fs = require("fs/promises");

/*
 * Collect storage usage information for a mounted filesystem.
 *
 * The mountPath parameter identifies the storage location that
 * should be measured, such as the main NVMe SSD or backup drive.
 */
async function getDiskUsage(mountPath) {
  try {
    /*
     * Read filesystem statistics for the requested mount path.
     *
     * The returned information includes:
     * - blocks: Total number of filesystem blocks
     * - bsize: Size of each block in bytes
     * - bavail: Blocks available to non-root users
     * - bfree: All free blocks, including root-reserved blocks
     */
    const stats = await fs.statfs(mountPath);

    // Calculate the filesystem's total capacity in bytes.
    const totalBytes = stats.blocks * stats.bsize;

    // Calculate the space available to regular, non-root users.
    const availableBytes = stats.bavail * stats.bsize;

    // Calculate all free space, including root-reserved space.
    const freeBytes = stats.bfree * stats.bsize;

    // Calculate used storage by subtracting free space from total space.
    const usedBytes = totalBytes - freeBytes;

    /*
     * Return the storage information in a frontend-friendly format.
     *
     * Byte values are converted to gigabytes and rounded to
     * one decimal place.
     */
    return {
      // Confirms that the mount path was found and measured successfully.
      available: true,

      // Total filesystem capacity in gigabytes.
      totalGB: Number((totalBytes / 1024 ** 3).toFixed(1)),

      // Currently used space in gigabytes.
      usedGB: Number((usedBytes / 1024 ** 3).toFixed(1)),

      /*
       * Space available to regular users in gigabytes.
       *
       * The property is named freeGB for display purposes, although
       * it uses Linux's "available" space rather than all free blocks.
       */
      freeGB: Number((availableBytes / 1024 ** 3).toFixed(1)),

      /*
       * Calculate the percentage of usable storage that is occupied.
       *
       * This calculation uses availableBytes so that filesystem space
       * reserved for the root user is not counted as normally available.
       */
      usagePercent: Number(
        ((usedBytes / (usedBytes + availableBytes)) * 100).toFixed(1)
      )
    };
  } catch {
    /*
     * If the path is missing, unmounted, or inaccessible, return an
     * unavailable status instead of crashing the entire dashboard.
     */
    return {
      available: false
    };
  }
}

/*
 * Collect metrics from both JuanCloud storage devices.
 *
 * Inside the container:
 * - /metrics/nvme represents the main NVMe/SSD storage.
 * - /metrics/backup represents the external backup drive.
 *
 * These paths are expected to be mounted as read-only volumes
 * in compose.yaml.
 */
async function getStorageMetrics() {
  /*
   * Read both devices concurrently because neither measurement
   * depends on the other.
   */
  const [nvme, backup] = await Promise.all([
    getDiskUsage("/metrics/nvme"),
    getDiskUsage("/metrics/backup")
  ]);

  // Return both results to server.js.
  return {
    nvme,
    backup
  };
}

/*
 * Export getStorageMetrics so server.js can import and use it
 * when processing requests to /api/status.
 */
module.exports = {
  getStorageMetrics
};
