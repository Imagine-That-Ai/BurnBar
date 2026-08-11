import { SafariExtensionError } from '../shared/errors';
import { viewportInfo } from './boxes';

interface FullPageCaptureState {
  token: string;
  originalScrollX: number;
  originalScrollY: number;
  originalScrollBehavior: string;
  pageWidth: number;
  pageHeight: number;
  viewportWidth: number;
  viewportHeight: number;
  devicePixelRatio: number;
}

export class FullPageCaptureCoordinator {
  private state: FullPageCaptureState | undefined;

  prepare(token: string): Omit<FullPageCaptureState, 'originalScrollBehavior'> {
    const viewport = viewportInfo();
    const root = document.documentElement;
    this.state = {
      token,
      originalScrollX: window.scrollX,
      originalScrollY: window.scrollY,
      originalScrollBehavior: root.style.scrollBehavior,
      pageWidth: viewport.pageWidth,
      pageHeight: viewport.pageHeight,
      viewportWidth: viewport.width,
      viewportHeight: viewport.height,
      devicePixelRatio: viewport.devicePixelRatio
    };
    root.style.scrollBehavior = 'auto';
    return {
      token,
      originalScrollX: this.state.originalScrollX,
      originalScrollY: this.state.originalScrollY,
      pageWidth: this.state.pageWidth,
      pageHeight: this.state.pageHeight,
      viewportWidth: this.state.viewportWidth,
      viewportHeight: this.state.viewportHeight,
      devicePixelRatio: this.state.devicePixelRatio
    };
  }

  async scroll(token: string, y: number): Promise<{ scrollX: number; scrollY: number }> {
    this.requireState(token);
    window.scrollTo({ left: 0, top: Math.max(0, y), behavior: 'auto' });
    await new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve())));
    return {
      scrollX: window.scrollX,
      scrollY: window.scrollY
    };
  }

  restore(token: string): { scrollX: number; scrollY: number } {
    const state = this.requireState(token);
    document.documentElement.style.scrollBehavior = state.originalScrollBehavior;
    window.scrollTo({ left: state.originalScrollX, top: state.originalScrollY, behavior: 'auto' });
    this.state = undefined;
    return {
      scrollX: state.originalScrollX,
      scrollY: state.originalScrollY
    };
  }

  private requireState(token: string): FullPageCaptureState {
    if (!this.state || this.state.token !== token) {
      throw new SafariExtensionError('capture_session_invalid', 'The full-page capture session is missing or stale.');
    }
    return this.state;
  }
}
