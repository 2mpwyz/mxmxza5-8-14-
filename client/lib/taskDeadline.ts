const DEADLINE_TIME_ZONE = "Africa/Kampala";
const DEADLINE_UTC_OFFSET = "+03:00";

export const toDeadlineInstant = (localDateTime: string) =>
  new Date(`${localDateTime}:00${DEADLINE_UTC_OFFSET}`).toISOString();

export const toDeadlineLocalInput = (instant: string) =>
  new Date(new Date(instant).getTime() + 3 * 60 * 60 * 1000)
    .toISOString()
    .slice(0, 16);

export const formatTaskDeadline = (instant: string) =>
  new Intl.DateTimeFormat("en-GB", {
    timeZone: DEADLINE_TIME_ZONE,
    day: "numeric",
    month: "short",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).format(new Date(instant));
