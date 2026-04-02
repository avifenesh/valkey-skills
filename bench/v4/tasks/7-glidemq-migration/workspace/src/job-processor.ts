import { Queue, Worker, FlowProducer, QueueEvents } from 'bullmq';
import IORedis from 'ioredis';

// --- Connection ---

const connection = new IORedis({ host: 'localhost', port: 6507 });

// --- Queue with default job options ---

const emailQueue = new Queue('emails', {
  connection,
  defaultJobOptions: {
    attempts: 3,
    backoff: { type: 'exponential', delay: 1000 },
  },
});

// --- Repeatable job using opts.repeat ---

export async function setupRepeatableJob(): Promise<void> {
  await emailQueue.add(
    'digest',
    { type: 'daily' },
    { repeat: { every: 86400000 } },
  );
}

// --- Worker with concurrency and custom backoff strategy ---

const worker = new Worker(
  'emails',
  async (job) => {
    console.log(`Processing job ${job.id}: ${job.name}`);
    return { processed: true, name: job.name, data: job.data };
  },
  {
    connection,
    concurrency: 5,
    settings: {
      backoffStrategy: (attemptsMade: number) => attemptsMade * 1000,
    },
  },
);

worker.on('completed', (job) => {
  console.log(`Job ${job?.id} completed`);
});

worker.on('failed', (job, err) => {
  console.error(`Job ${job?.id} failed: ${err.message}`);
});

// --- FlowProducer for parent-child DAGs ---

const flow = new FlowProducer({ connection });

export async function createBatchFlow(): Promise<void> {
  await flow.add({
    name: 'parent-job',
    queueName: 'emails',
    data: { type: 'batch' },
    children: [
      { name: 'child-1', queueName: 'emails', data: { id: 1 } },
      { name: 'child-2', queueName: 'emails', data: { id: 2 } },
    ],
  });
}

// --- QueueEvents for monitoring ---

const queueEvents = new QueueEvents('emails', { connection });

queueEvents.on('completed', ({ jobId }) => {
  console.log(`[event] Job ${jobId} completed`);
});

queueEvents.on('failed', ({ jobId, failedReason }) => {
  console.error(`[event] Job ${jobId} failed: ${failedReason}`);
});

// --- Wait for job completion with timeout ---

export async function addUrgentJob(): Promise<{ processed: boolean }> {
  const job = await emailQueue.add('urgent', { priority: 'high' });
  const result = await job.waitUntilFinished(queueEvents, 5000);
  return result;
}

// --- Exports for testing ---

export { emailQueue, worker, flow, queueEvents };
