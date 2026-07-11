use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::error::{BrokerError, ErrorCode};

pub trait RequestRateLimiter: Send + Sync {
    fn check(&self, uid: u32) -> Result<(), BrokerError>;
}

#[derive(Debug)]
pub struct PerUidRateLimiter {
    capacity: u32,
    refill_period: Duration,
    states: Mutex<HashMap<u32, Bucket>>,
}

#[derive(Clone, Copy, Debug)]
struct Bucket {
    tokens: f64,
    updated_at: Instant,
}

impl PerUidRateLimiter {
    pub fn new(capacity: u32, refill_period: Duration) -> Result<Self, BrokerError> {
        if capacity == 0 || refill_period.is_zero() {
            return Err(BrokerError::new(
                ErrorCode::Internal,
                "rate limiter configuration is invalid",
                false,
            ));
        }
        Ok(Self {
            capacity,
            refill_period,
            states: Mutex::new(HashMap::new()),
        })
    }
}

impl RequestRateLimiter for PerUidRateLimiter {
    fn check(&self, uid: u32) -> Result<(), BrokerError> {
        let now = Instant::now();
        let mut states = self.states.lock().map_err(|_| {
            BrokerError::new(
                ErrorCode::Internal,
                "rate limiter state is unavailable",
                false,
            )
        })?;

        // The daemon has one legitimate UID in normal operation. This bound prevents
        // hostile local users from growing the root service's state indefinitely.
        if states.len() >= 1_024 && !states.contains_key(&uid) {
            states.retain(|_, bucket| now.duration_since(bucket.updated_at) < self.refill_period);
            if states.len() >= 1_024 {
                return Err(BrokerError::new(
                    ErrorCode::RateLimited,
                    "broker request rate limit exceeded",
                    true,
                ));
            }
        }

        let bucket = states.entry(uid).or_insert(Bucket {
            tokens: f64::from(self.capacity),
            updated_at: now,
        });
        let elapsed = now.duration_since(bucket.updated_at).as_secs_f64();
        let refill_rate = f64::from(self.capacity) / self.refill_period.as_secs_f64();
        bucket.tokens = (bucket.tokens + elapsed * refill_rate).min(f64::from(self.capacity));
        bucket.updated_at = now;
        if bucket.tokens < 1.0 {
            return Err(BrokerError::new(
                ErrorCode::RateLimited,
                "broker request rate limit exceeded",
                true,
            ));
        }
        bucket.tokens -= 1.0;
        Ok(())
    }
}
