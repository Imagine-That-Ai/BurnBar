import { Component, type ErrorInfo, type ReactNode } from 'react';
import type { ShellRoute } from '../routes.js';
import './capability-boundary.css';

type SurfaceErrorBoundaryProps = {
  label: string;
  repairRoute: ShellRoute;
  onRepair: () => void;
  children: ReactNode;
};

type SurfaceErrorBoundaryState = {
  error: Error | null;
  retryNonce: number;
};

function normalizeRenderError(error: unknown): Error {
  if (error instanceof Error) return error;
  return new Error(typeof error === 'string' ? error : 'Unknown surface rendering error');
}

/** Keeps a single route failure recoverable without taking down the shell. */
export class SurfaceErrorBoundary extends Component<
  SurfaceErrorBoundaryProps,
  SurfaceErrorBoundaryState
> {
  state: SurfaceErrorBoundaryState = { error: null, retryNonce: 0 };

  static getDerivedStateFromError(error: unknown): SurfaceErrorBoundaryState {
    return { error: normalizeRenderError(error), retryNonce: 0 };
  }

  componentDidCatch(error: Error, info: ErrorInfo): void {
    // Keep the diagnostic local to the native shell boundary. The user-facing
    // fallback intentionally omits stack/details that may contain sensitive
    // provider or workspace paths.
    console.error('linux_surface_render_failed', {
      message: error.message,
      componentStack: info.componentStack
    });
  }

  private retry = (): void => {
    this.setState((current) => ({
      error: null,
      retryNonce: current.retryNonce + 1
    }));
  };

  render(): ReactNode {
    const { error, retryNonce } = this.state;
    if (error) {
      const titleID = `surface-error-${this.props.label.toLowerCase().replace(/[^a-z0-9]+/g, '-')}`;
      return (
        <section className="capability-boundary" role="alert" aria-labelledby={titleID}>
          <span className="capability-boundary__icon" aria-hidden="true">!</span>
          <div className="capability-boundary__body">
            <p className="capability-boundary__eyebrow">Route recovery</p>
            <h3 id={titleID}>{this.props.label} could not be rendered</h3>
            <p>
              OpenBurnBar kept the rest of the shell available. Retry this route or open Support to collect a
              redacted diagnostic without exposing provider credentials or workspace contents.
            </p>
            <button type="button" className="primary capability-boundary__action" onClick={this.retry}>
              Retry {this.props.label}
            </button>
            <button type="button" className="ghost capability-boundary__action" onClick={this.props.onRepair}>
              Open Support
            </button>
          </div>
        </section>
      );
    }

    return <div key={retryNonce}>{this.props.children}</div>;
  }
}
