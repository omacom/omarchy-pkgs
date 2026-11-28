// Checks the position filter of 0003-contacts-Add-a-speed-adaptive-position-filter.patch.

#include <contacts/contact.hpp>
#include <contacts/stability/stabilizer.hpp>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

using namespace iptsd;
using contacts::Contact;
using contacts::stability::Config;
using contacts::stability::Stabilizer;

using clock_type = Stabilizer<f64>::clock;

static int failures = 0;

// 120 frames per second on a 12 x 8 cm touchpad, as on the Surface Laptop 7.
static const f64 period = 1.0 / 120;
static const f64 width = 12;
static const f64 height = 8;

static clock_type::time_point frame_time(int frame)
{
	const auto offset = std::chrono::duration<f64>(frame * period);
	return clock_type::time_point {} + std::chrono::duration_cast<clock_type::duration>(offset);
}

static Contact<f64> at(usize index, f64 x_cm, f64 y_cm)
{
	Contact<f64> contact {};
	contact.index = index;
	contact.mean = Vector2<f64> {x_cm / width, y_cm / height};
	return contact;
}

// Runs one frame and returns where the first contact ended up, in cm.
static Vector2<f64> step(Stabilizer<f64> &stabilizer, int frame, std::vector<Contact<f64>> contacts)
{
	stabilizer.stabilize(contacts, frame_time(frame));

	if (contacts.empty())
		return Vector2<f64>::Zero();

	return Vector2<f64> {contacts[0].mean.x() * width, contacts[0].mean.y() * height};
}

static void expect(bool ok, const char *what)
{
	if (!ok) {
		std::fprintf(stderr, "not ok - %s\n", what);
		failures++;
	}
}

static Config<f64> filtered()
{
	// The values surface-laptop-7-touchpad.conf sets.
	Config<f64> config {};
	config.position_filter_min_cutoff = 1.5;
	config.position_filter_beta = 1.2;
	config.position_filter_speed_cutoff = 5;
	config.position_filter_scale = Vector2<f64> {width, height};
	return config;
}

int main()
{
	{
		Stabilizer<f64> stabilizer {Config<f64> {}};
		step(stabilizer, 0, {at(0, 6, 4)});
		const Vector2<f64> p = step(stabilizer, 1, {at(0, 6.01, 4)});
		expect(std::abs(p.x() - 6.01) < 1e-9, "without the filter a contact moves as before");
	}

	{
		Stabilizer<f64> stabilizer {filtered()};
		const Vector2<f64> p = step(stabilizer, 0, {at(0, 6, 4)});
		expect((p - Vector2<f64> {6, 4}).norm() < 1e-9, "a new contact starts where it appeared");
	}

	{
		// A contact at rest whose position jitters by 0.05 mm on both axes.
		Stabilizer<f64> stabilizer {filtered()};
		f64 low = 1e9;
		f64 high = -1e9;

		for (int i = 0; i < 240; i++) {
			const f64 jitter = (i % 2 == 0) ? 0.005 : -0.005;
			const Vector2<f64> p = step(stabilizer, i, {at(0, 6 + jitter, 4 - jitter)});

			if (i >= 120) {
				low = std::min(low, p.x());
				high = std::max(high, p.x());
			}
		}

		expect(high - low < 0.001, "the jitter of a contact at rest is smoothed to below 0.01 mm");
	}

	{
		// 300 mm/s along x: 2.5 mm per frame. Lag must stay below one frame.
		Stabilizer<f64> stabilizer {filtered()};
		Vector2<f64> p {};

		for (int i = 0; i < 60; i++)
			p = step(stabilizer, i, {at(0, 1 + i * 0.25, 4)});

		const f64 lag = (1 + 59 * 0.25 - p.x()) / 30; // seconds, at 30 cm/s
		expect(lag < period, "a fast contact lags by less than a frame");
	}

	{
		// 5 mm/s along x, with the same jitter: the output must not step backwards.
		Stabilizer<f64> stabilizer {filtered()};
		f64 last = 0;
		int reversals = 0;

		for (int i = 0; i < 240; i++) {
			const f64 jitter = (i % 2 == 0) ? 0.005 : -0.005;
			const Vector2<f64> p = step(stabilizer, i, {at(0, 3 + i * 0.5 * period + jitter, 4)});

			// Leave the filter a quarter second to pick up the speed.
			if (i > 30 && p.x() < last)
				reversals++;

			last = p.x();
		}

		expect(reversals == 0, "a slow contact moves steadily instead of back and forth");
	}

	{
		// Two contacts are filtered independently, and a lifted one starts over.
		Stabilizer<f64> stabilizer {filtered()};
		step(stabilizer, 0, {at(0, 2, 2), at(1, 8, 6)});
		step(stabilizer, 1, {at(0, 2, 2), at(1, 8, 6)});

		std::vector<Contact<f64>> frame {at(0, 2, 2), at(1, 8.001, 6)};
		stabilizer.stabilize(frame, frame_time(2));
		expect(std::abs(frame[0].mean.x() * width - 2) < 1e-9,
		       "a contact is not moved by another contact");

		step(stabilizer, 3, {at(1, 8, 6)});
		const Vector2<f64> p = step(stabilizer, 4, {at(0, 10, 7), at(1, 8, 6)});
		expect((p - Vector2<f64> {10, 7}).norm() < 1e-9,
		       "a lifted contact's index starts over where the next contact appears");
	}

	if (failures == 0)
		std::puts("ok - the position filter smooths slow contacts without delaying fast ones");

	return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
