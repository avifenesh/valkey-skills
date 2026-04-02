import { describe, it, expect } from 'vitest';
import { readFileSync } from 'fs';
import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const sourceCode = readFileSync(resolve(__dirname, 'job-processor.ts'), 'utf-8');
const pkgJson = JSON.parse(
  readFileSync(resolve(__dirname, '..', 'package.json'), 'utf-8'),
);

describe('BullMQ to glide-mq migration', () => {
  it('should use glide-mq connection format (addresses array)', () => {
    // Must have the addresses array format
    expect(sourceCode).toMatch(/addresses\s*:\s*\[/);
    // Must NOT have raw IORedis constructor
    expect(sourceCode).not.toMatch(/new\s+IORedis\s*\(/);
  });

  it('should not use defaultJobOptions (removed in glide-mq)', () => {
    expect(sourceCode).not.toMatch(/defaultJobOptions/);
  });

  it('should use upsertJobScheduler instead of repeat option', () => {
    // Must have upsertJobScheduler
    expect(sourceCode).toMatch(/upsertJobScheduler/);
    // Must NOT have repeat: { every: ... }
    expect(sourceCode).not.toMatch(/repeat\s*:\s*\{/);
  });

  it('should import from glide-mq not bullmq', () => {
    expect(sourceCode).toMatch(/from\s+['"]glide-mq['"]/);
    expect(sourceCode).not.toMatch(/from\s+['"]bullmq['"]/);
    expect(sourceCode).not.toMatch(/from\s+['"]ioredis['"]/);
  });

  it('should create FlowProducer with parent-child relationship', () => {
    expect(sourceCode).toMatch(/FlowProducer/);
    expect(sourceCode).toMatch(/children\s*:\s*\[/);
  });

  it('should use new waitUntilFinished signature (pollMs, timeoutMs)', () => {
    // glide-mq: job.waitUntilFinished(pollMs, timeoutMs)
    // NOT: job.waitUntilFinished(queueEvents, ttl)
    // The call should NOT pass queueEvents as first arg
    expect(sourceCode).not.toMatch(/waitUntilFinished\s*\(\s*queueEvents/);
    expect(sourceCode).toMatch(/waitUntilFinished\s*\(/);
  });

  it('should use backoffStrategies map instead of settings.backoffStrategy', () => {
    // Must NOT have settings.backoffStrategy
    expect(sourceCode).not.toMatch(/settings\s*:\s*\{[\s\S]*backoffStrategy/);
    // Must have backoffStrategies
    expect(sourceCode).toMatch(/backoffStrategies/);
  });

  it('should have glide-mq in package.json dependencies', () => {
    expect(pkgJson.dependencies).toHaveProperty('glide-mq');
    expect(pkgJson.dependencies).not.toHaveProperty('bullmq');
    expect(pkgJson.dependencies).not.toHaveProperty('ioredis');
  });
});
