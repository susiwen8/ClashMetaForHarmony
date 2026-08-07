export class SerialCommandQueue {
  private tail: Promise<void> = Promise.resolve();

  execute<T>(command: () => Promise<T>): Promise<T> {
    const previous: Promise<void> = this.tail;
    let releaseRef: (() => void) | undefined = undefined;
    this.tail = new Promise<void>((resolve) => {
      releaseRef = resolve;
    });

    const run = async (): Promise<T> => {
      await previous;
      try {
        return await command();
      } finally {
        releaseRef?.();
      }
    };

    return run();
  }
}
