let inflight = 0;
const pending: Array<() => void> = [];

export async function schedule(job: () => Promise<void>) {
  if (inflight >= 4) {
    await new Promise<void>(resolve => pending.push(resolve));
  }
  inflight++;
  try {
    await job();
  } finally {
    inflight--;
    pending.shift()?.();
  }
}
