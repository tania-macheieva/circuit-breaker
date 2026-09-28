# frozen_string_literal: true

require 'timeout'
require 'monitor'

class CircuitBreaker
  class OpenCircuitError < StandardError; end
  class CallTimeoutError < StandardError; end

  def initialize(failure_threshold:, half_open_max_calls:, open_state_duration:,
                 timeout_per_call:, clock: Time)
    @failure_threshold = failure_threshold
    @half_open_max_calls = half_open_max_calls
    @open_state_duration = open_state_duration
    @timeout_per_call = timeout_per_call
    @clock = clock

    @lock = Monitor.new
    @epoch = 0
    transition_to(:closed)
  end

  def state
    @lock.synchronize do
      half_open_if_ready
      @state
    end
  end

  def call(fn)
    mode, epoch = admit
    raise OpenCircuitError, 'circuit is open' if mode == :blocked

    begin
      result = Timeout.timeout(@timeout_per_call, CallTimeoutError) { fn.call }
    rescue StandardError # включає CallTimeoutError
      record(epoch, false)
      raise
    end

    record(epoch, true)
    result
  end

  private

  def admit
    @lock.synchronize do
      half_open_if_ready

      case @state
      when :closed
        [:normal, @epoch]
      when :half_open
        if @half_open_admitted < @half_open_max_calls
          @half_open_admitted += 1
          [:normal, @epoch]
        else
          [:blocked, @epoch]
        end
      else
        [:blocked, @epoch]
      end
    end
  end

  def record(epoch, success)
    @lock.synchronize do
      return if epoch != @epoch

      if success
        on_success
      else
        on_failure
      end
    end
  end

  def on_success
    case @state
    when :closed
      @failures = 0
    when :half_open
      @half_open_successes += 1
      transition_to(:closed) if @half_open_successes >= @half_open_max_calls
    end
  end

  def on_failure
    case @state
    when :closed
      @failures += 1
      transition_to(:open) if @failures >= @failure_threshold
    when :half_open
      transition_to(:open)
    end
  end

  def half_open_if_ready
    return unless @state == :open
    return if @clock.now - @opened_at < @open_state_duration

    transition_to(:half_open)
  end

  def transition_to(new_state)
    @state = new_state
    @epoch += 1
    @opened_at = @clock.now if new_state == :open
    @failures = 0
    @half_open_admitted = 0
    @half_open_successes = 0
  end
end
