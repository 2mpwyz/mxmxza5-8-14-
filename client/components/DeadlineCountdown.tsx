import { useEffect, useState } from "react";

const MINUTE = 60_000;
const HOUR = 60 * MINUTE;
const DAY = 24 * HOUR;

const formatDuration = (ms: number) => {
  if (ms >= DAY) {
    const days = Math.floor(ms / DAY);
    const hours = Math.floor((ms % DAY) / HOUR);
    const minutes = Math.floor((ms % HOUR) / MINUTE);
    return `${days}d ${hours}h ${minutes}m`;
  }
  if (ms >= HOUR) {
    const hours = Math.floor(ms / HOUR);
    const minutes = Math.floor((ms % HOUR) / MINUTE);
    const seconds = Math.floor((ms % MINUTE) / 1000);
    return `${hours}h ${minutes}m ${seconds}s`;
  }
  const minutes = Math.floor(ms / MINUTE);
  const seconds = Math.floor((ms % MINUTE) / 1000);
  return `${minutes}m ${seconds}s`;
};

interface DeadlineCountdownProps {
  dueDate: string;
  done: boolean;
  className?: string;
}

export default function DeadlineCountdown({ dueDate, done, className = "" }: DeadlineCountdownProps) {
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (done) return;
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [done]);

  if (done) {
    return <p className={`text-sm font-semibold text-emerald-600 dark:text-emerald-400 ${className}`}>Completed</p>;
  }

  const remaining = new Date(dueDate).getTime() - now;
  if (remaining < 0) {
    return (
      <p className={`text-sm font-semibold text-red-600 dark:text-red-400 ${className}`}>
        Overdue by {formatDuration(-remaining)}
      </p>
    );
  }

  return <p className={`text-sm font-semibold text-slate-600 dark:text-slate-300 ${className}`}>{formatDuration(remaining)} left</p>;
}
