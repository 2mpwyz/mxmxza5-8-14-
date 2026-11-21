const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const quoteCurrencies = ["USD", "EUR", "GBP", "KES", "TZS", "RWF"];
const cacheWindowMs = 10 * 60 * 1000;
const maxAgeMs = 36 * 60 * 60 * 1000;
const clockSkewMs = 5 * 60 * 1000;

type Source = {
  provider: string;
  url: string;
  read: (payload: any) => { rates?: Record<string, number>; time?: number } | null;
};

const sources: Source[] = [
  {
    provider: "exchangerate.fun",
    url: "https://api.exchangerate.fun/latest?base=UGX",
    read: (payload) => ({ rates: payload.rates, time: payload.timestamp }),
  },
  {
    provider: "open.er-api.com",
    url: "https://open.er-api.com/v6/latest/UGX",
    read: (payload) =>
      payload.result === "success"
        ? { rates: payload.rates, time: payload.time_last_update_unix }
        : null,
  },
];

const headers = {
  apikey: serviceRoleKey,
  Authorization: `Bearer ${serviceRoleKey}`,
  "content-type": "application/json",
};

const fetchLiveRates = async () => {
  for (const source of sources) {
    try {
      const response = await fetch(source.url, { signal: AbortSignal.timeout(8000) });
      if (!response.ok) continue;
      const parsed = source.read(await response.json());
      const rates = parsed?.rates;
      if (!rates || !parsed?.time) continue;
      const asOf = new Date(parsed.time * 1000);
      const covered = quoteCurrencies.every(
        (currency) => Number.isFinite(rates[currency]) && rates[currency] > 0,
      );
      const now = Date.now();
      const fresh = now - asOf.getTime() <= maxAgeMs && asOf.getTime() <= now + clockSkewMs;
      if (covered && fresh) return { rates, asOf, provider: source.provider };
    } catch {
      continue;
    }
  }
  throw new Error("No exchange-rate source returned usable rates");
};

const latestStoredAt = async () => {
  const response = await fetch(
    `${supabaseUrl}/rest/v1/books_fx_rates?base_currency=eq.UGX&select=stored_at&order=stored_at.desc&limit=1`,
    { headers },
  );
  if (!response.ok) throw new Error("Unable to read stored exchange rates");
  const rows = (await response.json()) as Array<{ stored_at: string }>;
  return rows[0] ? new Date(rows[0].stored_at).getTime() : 0;
};

Deno.serve(async () => {
  try {
    const lastStored = await latestStoredAt();
    if (Date.now() - lastStored < cacheWindowMs) {
      return Response.json({ skipped: true, reason: "rates are current" });
    }

    const live = await fetchLiveRates();
    const storedAt = new Date().toISOString();
    const rows = quoteCurrencies.map((currency) => ({
      base_currency: "UGX",
      quote_currency: currency,
      rate: live.rates![currency],
      provider: live.provider,
      fetched_at: live.asOf.toISOString(),
      stored_at: storedAt,
    }));

    const response = await fetch(
      `${supabaseUrl}/rest/v1/books_fx_rates?on_conflict=base_currency,quote_currency`,
      {
        method: "POST",
        headers: { ...headers, Prefer: "resolution=merge-duplicates,return=minimal" },
        body: JSON.stringify(rows),
      },
    );
    if (!response.ok) throw new Error("Unable to save exchange rates");

    return Response.json({ updated: rows.length, provider: live.provider, asOf: live.asOf });
  } catch (error) {
    console.error("Books FX refresh failed", error);
    return Response.json({ error: "Exchange rate refresh failed" }, { status: 503 });
  }
});
