# frozen_string_literal: true

require_relative 'circuit_breaker'

class FakeClock
  def initialize
    @now = Time.now
  end

  attr_reader :now

  def advance(seconds)
    @now += seconds
  end
end

RSpec.describe CircuitBreaker do
  let(:failure_threshold) { 3 }
  let(:half_open_max_calls) { 2 }
  let(:open_state_duration) { 5.0 }
  let(:timeout_per_call) { 0.1 }
  let(:clock) { FakeClock.new }

  subject(:breaker) do
    described_class.new(
      failure_threshold: failure_threshold,
      half_open_max_calls: half_open_max_calls,
      open_state_duration: open_state_duration,
      timeout_per_call: timeout_per_call,
      clock: clock
    )
  end

  let(:failing) { -> { raise 'boom' } }
  let(:hanging) { -> { sleep(timeout_per_call * 10) } }
  let(:succeeding) { -> { :ok } }

  def safe_call(fn)
    breaker.call(fn)
  rescue StandardError
    nil
  end

  def open_the_circuit
    failure_threshold.times { safe_call(failing) }
  end

  def go_half_open
    open_the_circuit
    clock.advance(open_state_duration)
  end

  describe 'Closed -> Open' do
    it 'starts Closed' do
      expect(breaker.state).to eq(:closed)
    end

    it 'stays Closed below the failure threshold' do
      (failure_threshold - 1).times { safe_call(failing) }
      expect(breaker.state).to eq(:closed)
    end

    it 'opens on the N-th consecutive failure' do
      (failure_threshold - 1).times { safe_call(failing) }
      expect { breaker.call(failing) }.to raise_error('boom')
      expect(breaker.state).to eq(:open)
    end

    it 'counts timeouts as failures' do
      failure_threshold.times do
        expect { breaker.call(hanging) }.to raise_error(CircuitBreaker::CallTimeoutError)
      end
      expect(breaker.state).to eq(:open)
    end

    it 'resets the failure counter after a success' do
      (failure_threshold - 1).times { safe_call(failing) }
      breaker.call(succeeding)
      (failure_threshold - 1).times { safe_call(failing) }
      expect(breaker.state).to eq(:closed)
    end

    it 'returns the result of fn and re-raises its errors' do
      expect(breaker.call(-> { 42 })).to eq(42)
      expect { breaker.call(failing) }.to raise_error('boom')
    end
  end

  describe 'Open' do
    before { open_the_circuit }

    it 'blocks calls without invoking fn' do
      fn = double('dependency')
      expect(fn).not_to receive(:call)

      expect { breaker.call(fn) }.to raise_error(CircuitBreaker::OpenCircuitError)
    end

    it 'stays Open until openStateDuration has fully passed' do
      clock.advance(open_state_duration - 0.001)
      expect(breaker.state).to eq(:open)
      expect { breaker.call(succeeding) }.to raise_error(CircuitBreaker::OpenCircuitError)
    end

    it 'becomes HalfOpen once openStateDuration has passed' do
      clock.advance(open_state_duration)
      expect(breaker.state).to eq(:half_open)
    end
  end

  describe 'HalfOpen' do
    before { go_half_open }

    it 'closes after halfOpenMaxCalls successful trial calls' do
      (half_open_max_calls - 1).times { breaker.call(succeeding) }
      expect(breaker.state).to eq(:half_open)

      breaker.call(succeeding)
      expect(breaker.state).to eq(:closed)
    end

    it 'reopens immediately when a trial call fails' do
      safe_call(failing)
      expect(breaker.state).to eq(:open)
    end

    it 'reopens immediately when a trial call times out' do
      expect { breaker.call(hanging) }.to raise_error(CircuitBreaker::CallTimeoutError)
      expect(breaker.state).to eq(:open)
    end

    it 'restarts the openStateDuration timer after reopening' do
      safe_call(failing)
      clock.advance(open_state_duration - 0.001)
      expect(breaker.state).to eq(:open)

      clock.advance(0.001)
      expect(breaker.state).to eq(:half_open)
    end

    context 'with concurrent trial calls' do
      let(:timeout_per_call) { 5.0 }

      it 'admits at most halfOpenMaxCalls trial calls' do
        started = Queue.new
        release = Queue.new

        trials = half_open_max_calls.times.map do
          Thread.new { breaker.call(-> { started << true; release.pop; :ok }) }
        end
        half_open_max_calls.times { started.pop }

        extra = double('dependency')
        expect(extra).not_to receive(:call)
        expect { breaker.call(extra) }.to raise_error(CircuitBreaker::OpenCircuitError)

        half_open_max_calls.times { release << true }
        trials.each(&:join)
        expect(breaker.state).to eq(:closed)
      end
    end
  end

  describe 'per-call timeout' do
    it 'raises CallTimeoutError when fn exceeds timeoutPerCall' do
      expect { breaker.call(hanging) }.to raise_error(CircuitBreaker::CallTimeoutError)
    end

    it 'does not interrupt fn that finishes in time' do
      expect(breaker.call(-> { sleep(timeout_per_call / 10); :done })).to eq(:done)
      expect(breaker.state).to eq(:closed)
    end
  end
end