## The one reader of a url parameter that is a number of milliseconds (`busy_timeout`, `timeout_ms`), shared by the url
## readers of the adapters, which word their own errors.

MAX_DIGITS = 9
DIGIT_ZERO = 48
DIGIT_NINE = 57

## A non-empty run of ASCII digits, at most nine (about 11 days): far from any overflow in the clock arithmetic of a
## wait or a timeout. Anything else (a sign, a space, a percent escape) is none.
export def parse(text: String) -> Optional[Int]
  bytes = text.bytes.to_a
  not_digits = bytes.any? do |byte| byte < DIGIT_ZERO or byte > DIGIT_NINE end
  return none if bytes.empty? or bytes.size > MAX_DIGITS or not_digits

  some(text.to_i.unwrap_or(0))
end
